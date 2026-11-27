// fancurved — FanCurve privileged helper (runs as root under launchd).
//
// Listens on a Unix socket. The FanCurve app connects, sends a curve, and polls state.
// The helper applies the curve once per second ONLY while the controlling app stays
// connected. Disconnect, crash, signal, bad sensors or an SMC error → fans go back to macOS.
//
// Protocol: one JSON object per line, one JSON reply per line.
//   {"cmd":"hello"}                                   → {"ok":true,"version":N}
//   {"cmd":"state"}                                   → state
//   {"cmd":"control","enabled":true,"points":[[t,f],…],"response":45} → state
//     response: seconds the curve takes to follow the core temperature (0 = at once, default 0)
//   {"cmd":"release"}                                 → state
//
// Usage: fancurved [--socket PATH] [--owner UID] [--fake]
//   --fake  simulate fans in memory (for tests without root); temperatures stay real
//           unless FANCURVE_FAKE_TEMP is set.
#import <Foundation/Foundation.h>
#include <IOKit/IOKitLib.h>
#include <sys/socket.h>
#include <sys/un.h>
#include <sys/stat.h>
#include <poll.h>
#include <signal.h>
#include <unistd.h>
#include <fcntl.h>
#include <errno.h>
#include <math.h>

#define HELPER_VERSION 5
#define MAX_CLIENTS 8
#define MAX_POINTS 12
// Fail-safe: 100 % at once. Apple Silicon cores run at 95–100 °C under heavy load by design,
// so the hottest core gets a high limit; the average is the main signal. Leaving needs a margin
// (FAILSAFE_*_OFF) so the fans don't flap on and off around the limit.
#define FAILSAFE_AVG 95.0
#define FAILSAFE_HOT 105.0
#define FAILSAFE_AVG_OFF 90.0
#define FAILSAFE_HOT_OFF 100.0
// Fan level slew limit, % per second. 0 → 100 % takes about 50 s, so the sound grows slowly;
// slowing down is quicker so the fans don't stay loud long after the load is gone.
#define RAMP_UP 2.0
#define RAMP_DOWN 3.0
// Thermal inertia: the curve follows a smoothed core temperature, so a short burst of load
// (a test run, a build) does not send the fans to full speed while the case is still cold.
// The time constant comes from the app. Above SOFT_FROM °C it shrinks smoothly, down to
// SOFT_MIN of itself near the fail-safe, so real heat is followed sooner without any jump.
// Cooling is followed FALL_DIVISOR times faster than heating.
// The fail-safe always looks at the raw temperature.
#define MAX_RESPONSE 300.0
#define FALL_DIVISOR 3.0
#define SOFT_FROM 80.0
#define SOFT_MIN 0.2

static BOOL fake = NO;
double fakeTemp = NAN;  // --fake only: set by the "fake-temp" command in tests
static const char *socketPath = "/var/run/fancurve.sock";

// ============================================================ temperatures (IOHID)
typedef struct __IOHIDEvent *IOHIDEventRef;
typedef struct __IOHIDServiceClient *IOHIDServiceClientRef;
typedef struct __IOHIDEventSystemClient *IOHIDEventSystemClientRef;
extern IOHIDEventSystemClientRef IOHIDEventSystemClientCreate(CFAllocatorRef);
extern int IOHIDEventSystemClientSetMatching(IOHIDEventSystemClientRef, CFDictionaryRef);
extern CFArrayRef IOHIDEventSystemClientCopyServices(IOHIDEventSystemClientRef);
extern IOHIDEventRef IOHIDServiceClientCopyEvent(IOHIDServiceClientRef, int64_t, int32_t, int64_t);
extern CFTypeRef IOHIDServiceClientCopyProperty(IOHIDServiceClientRef, CFStringRef);
extern double IOHIDEventGetFloatValue(IOHIDEventRef, int32_t);
#define kIOHIDEventTypeTemperature 15

typedef struct { double avg, hot, ssd, battery; int n; } Temps;

static Temps readTemps(void) {
    static IOHIDEventSystemClientRef hid;
    static CFArrayRef services;
    if (!hid) {
        hid = IOHIDEventSystemClientCreate(kCFAllocatorDefault);
        NSDictionary *m = @{@"PrimaryUsagePage": @0xff00, @"PrimaryUsage": @5};
        IOHIDEventSystemClientSetMatching(hid, (__bridge CFDictionaryRef)m);
        services = IOHIDEventSystemClientCopyServices(hid);
    }
    Temps t = {NAN, NAN, NAN, NAN, 0};
    double sum = 0;
    CFIndex count = services ? CFArrayGetCount(services) : 0;
    for (CFIndex i = 0; i < count; i++) {
        IOHIDServiceClientRef sc = (IOHIDServiceClientRef)CFArrayGetValueAtIndex(services, i);
        CFTypeRef nameRef = IOHIDServiceClientCopyProperty(sc, CFSTR("Product"));
        NSString *name = nameRef ? (__bridge_transfer NSString *)nameRef : @"";
        IOHIDEventRef e = IOHIDServiceClientCopyEvent(sc, kIOHIDEventTypeTemperature, 0, 0);
        if (!e) continue;
        double v = IOHIDEventGetFloatValue(e, kIOHIDEventTypeTemperature << 16);
        CFRelease(e);
        if (v < -50 || v > 150) continue;  // unused sensors report garbage
        if ([name hasPrefix:@"PMU tdie"]) { sum += v; t.n++; if (isnan(t.hot) || v > t.hot) t.hot = v; }
        else if ([name hasPrefix:@"NAND"]) { if (isnan(t.ssd) || v > t.ssd) t.ssd = v; }
        else if ([name hasPrefix:@"gas gauge"]) { if (isnan(t.battery) || v > t.battery) t.battery = v; }
    }
    if (t.n) t.avg = sum / t.n;
    extern double fakeTemp;
    const char *ft = getenv("FANCURVE_FAKE_TEMP");
    double forced = !isnan(fakeTemp) ? fakeTemp : (ft && *ft ? atof(ft) : NAN);
    if (fake && !isnan(forced)) { t.avg = forced; t.hot = t.avg + 5; t.n = t.n ? t.n : 1; }
    return t;
}

// ============================================================ AppleSMC
typedef struct { char major, minor, build, reserved[1]; UInt16 release; } SMCVers;
typedef struct { UInt16 version, length; UInt32 cpuPLimit, gpuPLimit, memPLimit; } SMCPLimit;
typedef struct { UInt32 dataSize, dataType; char dataAttributes; } SMCKeyInfo;
typedef struct {
    UInt32 key; SMCVers vers; SMCPLimit pLimitData; SMCKeyInfo keyInfo;
    char result, status, data8; UInt32 data32; unsigned char bytes[32];
} SMCKeyData;
enum { kSMCUserClient = 2, kSMCRead = 5, kSMCWrite = 6, kSMCKeyInfoCmd = 9 };

static io_connect_t smc;

static UInt32 fcc(const char *s) { return ((UInt32)s[0] << 24) | ((UInt32)s[1] << 16) | ((UInt32)s[2] << 8) | (UInt32)s[3]; }

static BOOL smcOpen(void) {
    if (smc) return YES;
    io_service_t svc = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSMC"));
    if (!svc) return NO;
    kern_return_t kr = IOServiceOpen(svc, mach_task_self(), 0, &smc);
    IOObjectRelease(svc);
    return kr == KERN_SUCCESS;
}

static int smcCall(SMCKeyData *in, SMCKeyData *out) {
    size_t sz = sizeof(SMCKeyData);
    kern_return_t kr = IOConnectCallStructMethod(smc, kSMCUserClient, in, sizeof(SMCKeyData), out, &sz);
    if (kr != KERN_SUCCESS) return (int)kr;
    return (unsigned char)out->result;
}

static int smcInfo(const char *key, SMCKeyInfo *info) {
    SMCKeyData in = {0}, out = {0};
    in.key = fcc(key); in.data8 = kSMCKeyInfoCmd;
    int r = smcCall(&in, &out);
    if (r == 0) *info = out.keyInfo;
    return r;
}

static double smcReadNum(const char *key) {
    SMCKeyInfo info;
    if (smcInfo(key, &info) != 0) return NAN;
    SMCKeyData in = {0}, out = {0};
    in.key = fcc(key); in.keyInfo.dataSize = info.dataSize; in.data8 = kSMCRead;
    if (smcCall(&in, &out) != 0) return NAN;
    const unsigned char *b = out.bytes;
    UInt32 t = info.dataType;
    if (t == fcc("flt ") && info.dataSize == 4) { float f; memcpy(&f, b, 4); return f; }
    if (t == fcc("ui8 ")) return b[0];
    if (t == fcc("ui16")) return (b[0] << 8) | b[1];
    return NAN;
}

static int smcWriteNum(const char *key, double v) {
    SMCKeyInfo info;
    int r = smcInfo(key, &info);
    if (r != 0) return r;
    SMCKeyData in = {0}, out = {0};
    in.key = fcc(key); in.data8 = kSMCWrite; in.keyInfo.dataSize = info.dataSize;
    if (info.dataType == fcc("flt ")) { float f = (float)v; memcpy(in.bytes, &f, 4); }
    else if (info.dataType == fcc("ui8 ")) in.bytes[0] = (unsigned char)v;
    else return -2;
    return smcCall(&in, &out);
}

static void fkey(char *buf, int fan, const char *suffix) { snprintf(buf, 5, "F%d%s", fan, suffix); }

// Mode key: "F<n>md" on M5, "F<n>Md" on earlier Apple Silicon.
static BOOL modeKey(char *buf, int fan) {
    SMCKeyInfo info;
    fkey(buf, fan, "md");
    if (smcInfo(buf, &info) == 0) return YES;
    fkey(buf, fan, "Md");
    return smcInfo(buf, &info) == 0;
}

// ============================================================ fans (real or fake)
typedef struct { double actual, min, max, target; BOOL manual; } Fan;
static Fan fakeFans[2] = {{1350, 1350, 5349, 1350, NO}, {1350, 1350, 5777, 1350, NO}};

static int fanCount(void) {
    if (fake) return 2;
    if (!smcOpen()) return 0;
    double n = smcReadNum("FNum");
    return isnan(n) ? 0 : (int)fmin(n, 4);
}

static Fan fanRead(int i) {
    if (fake) {
        Fan *f = &fakeFans[i];
        double goal = f->manual ? f->target : f->min;
        f->actual += (goal - f->actual) * 0.5;  // spin-up lag
        return *f;
    }
    Fan f; char k[5];
    fkey(k, i, "Ac"); f.actual = smcReadNum(k);
    fkey(k, i, "Mn"); f.min = smcReadNum(k);
    fkey(k, i, "Mx"); f.max = smcReadNum(k);
    fkey(k, i, "Tg"); f.target = smcReadNum(k);
    f.manual = modeKey(k, i) && smcReadNum(k) >= 1;
    return f;
}

// Returns nil on success, an error message otherwise.
static NSString *fanSet(int i, double rpm, double mn, double mx) {
    rpm = fmax(mn, fmin(mx, rpm));  // never below Apple's minimum, never above max
    if (fake) {
        if (getenv("FANCURVE_FAKE_REFUSE")) return @"SMC refused manual mode (simulated)";
        fakeFans[i].manual = YES; fakeFans[i].target = rpm; return nil;
    }
    char k[5];
    if (!modeKey(k, i)) return @"no fan mode key on this Mac";
    if (smcReadNum(k) != 1) {
        int r = smcWriteNum(k, 1);
        if (r != 0 || smcReadNum(k) != 1)
            return [NSString stringWithFormat:@"SMC refused manual mode (0x%x)%@", r, geteuid() ? @", helper is not root" : @""];
    }
    fkey(k, i, "Tg");
    int r = smcWriteNum(k, rpm);
    return r ? [NSString stringWithFormat:@"SMC refused fan target (0x%x)", r] : nil;
}

static void fansAuto(void) {
    int n = fanCount();
    for (int i = 0; i < n; i++) {
        if (fake) { fakeFans[i].manual = NO; continue; }
        char k[5];
        if (modeKey(k, i)) smcWriteNum(k, 0);
    }
}

// ============================================================ control state
static int controller = -1;           // fd of the client that controls the fans
static BOOL ctlEnabled = NO;
static double pts[MAX_POINTS][2];
static int npts = 0;
static double pct = NAN;              // current fan level 0–100 (curve + ramp), NaN = not controlling
static BOOL failsafe = NO, manualActive = NO;
// Write throttle: targets go to the SMC at most every WRITE_INTERVAL s, and only when a fan's
// target moves by ≥ WRITE_THRESHOLD of what we last wrote. Fail-safe, first write, a new curve
// and reaching min/max skip both rules.
#define WRITE_INTERVAL 3.0
#define WRITE_THRESHOLD 0.03
static double writtenRPM[4] = {NAN, NAN, NAN, NAN};
static double appliedPct = NAN;       // level that the fans were last actually set to
static double lastWrite = -1e9;
static BOOL forceWrite = YES;
static double now(void);
static NSString *lastError = nil;
static NSDictionary *lastState = nil;
static double response = 0;           // rise time constant, s
static double smoothT = NAN;          // temperature the curve sees; NaN = start from the raw value
static double lastSmooth = NAN;       // time of the last smoothing step
static double rampUp = RAMP_UP, rampDown = RAMP_DOWN;  // --fake tests may override (FANCURVE_FAKE_RAMP)
static double lastRamp = NAN;         // time of the last slew step; steps scale with elapsed time

// One smoothing step (exponential moving average over real elapsed time).
static double smoothStep(double raw) {
    double t = now();
    if (isnan(raw)) return smoothT;
    if (isnan(smoothT) || isnan(lastSmooth) || response <= 0) { smoothT = raw; lastSmooth = t; return smoothT; }
    double dt = fmax(0, t - lastSmooth);
    lastSmooth = t;
    double tau = raw > smoothT ? response : response / FALL_DIVISOR;
    if (raw > smoothT && raw > SOFT_FROM)
        tau *= fmax(SOFT_MIN, fmin(1, (FAILSAFE_AVG - raw) / (FAILSAFE_AVG - SOFT_FROM)));
    smoothT += (raw - smoothT) * (1 - exp(-dt / tau));
    return smoothT;
}

static double curvePct(double t) {
    if (t <= pts[0][0]) return pts[0][1];
    for (int i = 1; i < npts; i++)
        if (t <= pts[i][0])
            return pts[i - 1][1] + (pts[i][1] - pts[i - 1][1]) * (t - pts[i - 1][0]) / (pts[i][0] - pts[i - 1][0]);
    return pts[npts - 1][1];
}

static void giveBack(void) {
    if (manualActive) fansAuto();
    manualActive = NO; pct = NAN; failsafe = NO; lastRamp = NAN;
    appliedPct = NAN; forceWrite = YES;
    for (int i = 0; i < 4; i++) writtenRPM[i] = NAN;
}

// Should the new target for one fan be written now?
static BOOL needsWrite(int i, double rpm, double mn, double mx, BOOL urgent) {
    double w = writtenRPM[i];
    if (urgent || isnan(w)) return YES;
    if (fabs(rpm - w) < 1) return NO;
    if ((rpm <= mn || rpm >= mx) && fabs(rpm - w) >= 1) return YES;  // reach the ends exactly
    return now() - lastWrite >= WRITE_INTERVAL && fabs(rpm - w) / fmax(w, 1) >= WRITE_THRESHOLD;
}

static id jnum(double v, double scale) { return isnan(v) ? (id)[NSNull null] : @(round(v * scale) / scale); }

static void tick(void) {
    Temps t = readTemps();
    int n = fanCount();
    Fan fans[4];
    for (int i = 0; i < n; i++) fans[i] = fanRead(i);
    double eff = smoothStep(t.avg);

    BOOL control = controller >= 0 && ctlEnabled && npts >= 2 && !lastError && n > 0 && !isnan(t.avg);
    if (control) {
        double want = curvePct(eff);
        BOOL wasFailsafe = failsafe;
        failsafe = t.hot >= FAILSAFE_HOT || t.avg >= FAILSAFE_AVG
                   || (failsafe && (t.hot >= FAILSAFE_HOT_OFF || t.avg >= FAILSAFE_AVG_OFF));
        if (failsafe) want = 100;
        // Slew by elapsed time, not per tick: extra ticks from app commands don't speed it up.
        double tn = now(), dt = isnan(lastRamp) ? 1 : fmax(0, fmin(2, tn - lastRamp));
        lastRamp = tn;
        if (isnan(pct) || failsafe) pct = want;
        else if (want > pct) pct = fmin(want, pct + rampUp * dt);
        else pct = fmax(want, pct - rampDown * dt);
        BOOL urgent = forceWrite || failsafe != wasFailsafe;
        BOOL wrote = NO;
        for (int i = 0; i < n && !lastError; i++) {
            if (isnan(fans[i].min) || isnan(fans[i].max)) continue;
            double rpm = fmax(fans[i].min, fmin(fans[i].max, fans[i].min + pct / 100 * (fans[i].max - fans[i].min)));
            if (!needsWrite(i, rpm, fans[i].min, fans[i].max, urgent)) continue;
            NSString *err = fanSet(i, rpm, fans[i].min, fans[i].max);
            manualActive = YES;
            if (err) lastError = err; else { writtenRPM[i] = rpm; wrote = YES; }
        }
        if (wrote) { lastWrite = now(); appliedPct = pct; }
        forceWrite = NO;
        if (lastError) giveBack();
    } else {
        giveBack();
    }
    for (int i = 0; i < n; i++) {  // report what the fans look like after our writes
        Fan f = fanRead(i);
        fans[i].target = f.target; fans[i].manual = f.manual;
    }

    NSString *mode = lastError ? @"error" : !control ? @"auto" : failsafe ? @"failsafe" : @"curve";
    NSMutableArray *fa = [NSMutableArray array];
    for (int i = 0; i < n; i++)
        [fa addObject:@{@"actual": jnum(fans[i].actual, 1), @"min": jnum(fans[i].min, 1), @"max": jnum(fans[i].max, 1),
                        @"target": jnum(fans[i].target, 1), @"manual": [NSNumber numberWithBool:fans[i].manual]}];
    lastState = @{
        @"version": @HELPER_VERSION, @"mode": mode, @"error": lastError ?: [NSNull null],
        @"cpu": @{@"avg": jnum(t.avg, 10), @"max": jnum(t.hot, 10), @"sensors": @(t.n), @"effective": jnum(eff, 10)},
        @"response": @(response),
        @"ssd": jnum(t.ssd, 10), @"battery": jnum(t.battery, 10),
        @"fans": fa, @"pct": jnum(pct, 10), @"applied": jnum(appliedPct, 10), @"fake": @(fake),
        @"failsafe": @{@"avg": @FAILSAFE_AVG, @"hottest": @FAILSAFE_HOT},
    };
}

// Validates and stores a curve. Returns an error message or nil.
static NSString *setCurve(NSArray *points) {
    if (![points isKindOfClass:NSArray.class] || points.count < 2 || points.count > MAX_POINTS) return @"need 2–12 points";
    double tmp[MAX_POINTS][2];
    for (NSUInteger i = 0; i < points.count; i++) {
        NSArray *p = points[i];
        if (![p isKindOfClass:NSArray.class] || p.count != 2 || ![p[0] isKindOfClass:NSNumber.class] || ![p[1] isKindOfClass:NSNumber.class])
            return @"bad point";
        tmp[i][0] = [p[0] doubleValue]; tmp[i][1] = [p[1] doubleValue];
        if (!(tmp[i][0] >= 20 && tmp[i][0] <= 105 && tmp[i][1] >= 0 && tmp[i][1] <= 100)) return @"point out of range";
        if (i && tmp[i][0] - tmp[i - 1][0] < 1) return @"points must go up by at least 1 °C";
    }
    for (NSUInteger i = 0; i < points.count; i++) {
        pts[i][0] = tmp[i][0];
        pts[i][1] = i ? fmax(tmp[i][1], pts[i - 1][1]) : tmp[i][1];  // hotter never means slower
    }
    npts = (int)points.count;
    return nil;
}

// ============================================================ socket server
typedef struct { int fd; char buf[8192]; size_t len; } Client;
static Client clients[MAX_CLIENTS];
static int nclients = 0;
static int listenFd = -1;
static uid_t ownerUid = 0;

static void sendJSON(int fd, NSDictionary *d) {
    NSData *j = [NSJSONSerialization dataWithJSONObject:d options:0 error:nil];
    NSMutableData *m = [j mutableCopy];
    [m appendBytes:"\n" length:1];
    send(fd, m.bytes, m.length, MSG_DONTWAIT);  // replies are small; a stuck client just misses one
}

static NSDictionary *stateFor(int fd) {
    NSMutableDictionary *d = [(lastState ?: @{}) mutableCopy];
    d[@"controlling"] = [NSNumber numberWithBool:controller == fd];
    d[@"ok"] = @YES;
    return d;
}

static void dropClient(int idx) {
    int fd = clients[idx].fd;
    close(fd);
    clients[idx] = clients[--nclients];
    if (controller == fd) { controller = -1; giveBack(); if (nclients) tick(); }
}

static void handle(int fd, NSData *line) {
    NSDictionary *req = [NSJSONSerialization JSONObjectWithData:line options:0 error:nil];
    if (![req isKindOfClass:NSDictionary.class]) { sendJSON(fd, @{@"ok": @NO, @"error": @"bad json"}); return; }
    NSString *cmd = req[@"cmd"];
    if ([cmd isEqual:@"hello"]) { sendJSON(fd, @{@"ok": @YES, @"version": @HELPER_VERSION}); return; }
    if ([cmd isEqual:@"state"]) { if (!lastState) tick(); sendJSON(fd, stateFor(fd)); return; }
    if ([cmd isEqual:@"release"]) {
        if (controller == fd) { controller = -1; giveBack(); }
        tick(); sendJSON(fd, stateFor(fd)); return;
    }
    if (fake && [cmd isEqual:@"fake-temp"]) {
        fakeTemp = [req[@"value"] isKindOfClass:NSNumber.class] ? [req[@"value"] doubleValue] : NAN;
        sendJSON(fd, @{@"ok": @YES}); return;
    }
    if ([cmd isEqual:@"control"]) {
        NSString *err = setCurve(req[@"points"]);
        if (err) { sendJSON(fd, @{@"ok": @NO, @"error": err}); return; }
        id r = req[@"response"];
        response = [r isKindOfClass:NSNumber.class] ? fmax(0, fmin(MAX_RESPONSE, [r doubleValue])) : 0;
        BOOL en = [req[@"enabled"] boolValue];
        if (en && (!ctlEnabled || controller != fd)) lastError = nil;  // (re)enabling retries after an error
        controller = fd; ctlEnabled = en;
        forceWrite = YES;  // a new curve or profile applies at once, no 3 s wait
        tick(); sendJSON(fd, stateFor(fd)); return;
    }
    sendJSON(fd, @{@"ok": @NO, @"error": @"unknown command"});
}

static void readClient(int idx) {
    Client *c = &clients[idx];
    ssize_t r = recv(c->fd, c->buf + c->len, sizeof c->buf - c->len, 0);
    if (r <= 0) { dropClient(idx); return; }
    c->len += r;
    char *nl;
    while ((nl = memchr(c->buf, '\n', c->len))) {
        size_t n = nl - c->buf;
        @autoreleasepool { handle(c->fd, [NSData dataWithBytes:c->buf length:n]); }
        memmove(c->buf, nl + 1, c->len - n - 1);
        c->len -= n + 1;
    }
    if (c->len == sizeof c->buf) dropClient(idx);  // line too long
}

static void acceptClient(void) {
    int fd = accept(listenFd, NULL, NULL);
    if (fd < 0) return;
    uid_t uid; gid_t gid;
    if (getpeereid(fd, &uid, &gid) != 0 || (uid != ownerUid && uid != 0) || nclients == MAX_CLIENTS) { close(fd); return; }
    int one = 1;
    setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, sizeof one);
    clients[nclients].fd = fd; clients[nclients].len = 0; nclients++;
}

static void onSignal(int sig) {
    if (manualActive || !fake) fansAuto();
    unlink(socketPath);
    _exit(sig == SIGTERM ? 0 : 128 + sig);
}

static double now(void) { struct timespec ts; clock_gettime(CLOCK_MONOTONIC, &ts); return ts.tv_sec + ts.tv_nsec / 1e9; }

int main(int argc, const char **argv) {
    @autoreleasepool {
        ownerUid = getuid();
        for (int i = 1; i < argc; i++) {
            if (!strcmp(argv[i], "--fake")) fake = YES;
            else if (!strcmp(argv[i], "--socket") && i + 1 < argc) socketPath = argv[++i];
            else if (!strcmp(argv[i], "--owner") && i + 1 < argc) ownerUid = (uid_t)atoi(argv[++i]);
            else if (!strcmp(argv[i], "--version")) { printf("%d\n", HELPER_VERSION); return 0; }
            else { fprintf(stderr, "usage: fancurved [--socket PATH] [--owner UID] [--fake]\n"); return 1; }
        }
        const char *fr = getenv("FANCURVE_FAKE_RAMP");  // "up,down" — tests only
        if (fake && fr && sscanf(fr, "%lf,%lf", &rampUp, &rampDown) != 2) { rampUp = RAMP_UP; rampDown = RAMP_DOWN; }
        if (sizeof(SMCKeyData) != 80) { fprintf(stderr, "bad SMC struct size\n"); return 2; }

        signal(SIGINT, onSignal); signal(SIGTERM, onSignal); signal(SIGHUP, onSignal);
        signal(SIGPIPE, SIG_IGN);
        if (!fake) fansAuto();  // crash recovery: never start with fans stuck in manual

        listenFd = socket(AF_UNIX, SOCK_STREAM, 0);
        struct sockaddr_un addr = {.sun_family = AF_UNIX};
        if (strlen(socketPath) >= sizeof addr.sun_path) { fprintf(stderr, "socket path too long\n"); return 1; }
        strcpy(addr.sun_path, socketPath);
        unlink(socketPath);
        mode_t old = umask(0177);
        if (bind(listenFd, (struct sockaddr *)&addr, sizeof addr) != 0 || listen(listenFd, 8) != 0) {
            perror("bind/listen"); return 1;
        }
        umask(old);
        chown(socketPath, ownerUid, (gid_t)-1);
        chmod(socketPath, 0600);
        fprintf(stderr, "fancurved %d listening on %s (owner %d%s)\n", HELPER_VERSION, socketPath, ownerUid, fake ? ", fake fans" : "");

        double next = now();
        for (;;) {
            struct pollfd pf[MAX_CLIENTS + 1];
            pf[0] = (struct pollfd){.fd = listenFd, .events = POLLIN};
            for (int i = 0; i < nclients; i++) pf[i + 1] = (struct pollfd){.fd = clients[i].fd, .events = POLLIN};
            int timeout = nclients ? (int)fmax(0, (next - now()) * 1000) : -1;  // idle: sleep until someone connects
            int r = poll(pf, nclients + 1, timeout);
            if (r < 0 && errno != EINTR) { perror("poll"); break; }
            if (r > 0) {
                int snapshot = nclients;
                for (int i = snapshot - 1; i >= 0; i--)
                    if (pf[i + 1].revents & (POLLIN | POLLHUP | POLLERR)) readClient(i);
                if (pf[0].revents & POLLIN) acceptClient();
            }
            if (nclients && now() >= next) {
                @autoreleasepool { tick(); }
                next = now() + 1.0;
            }
            if (!nclients) { giveBack(); lastState = nil; smoothT = NAN; next = now(); }
        }
        fansAuto();
    }
    return 0;
}

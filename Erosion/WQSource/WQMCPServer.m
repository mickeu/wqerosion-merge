//
//  WQMCPServer.m
//  WQ Files — MCP server over localhost HTTP. GPL-3.0-or-later.
//
//  v1 scope: JSON-RPC over HTTP on 127.0.0.1:18765, Bearer auth, tools
//  search / read / plan / commit / backups. File mutations (write, delete,
//  rename, mkdir, move) go plan -> commit. App-container backup/clear/restore
//  are listed via `backups`; the app_* mutations are wired in Stage 1.5
//  (needs public wrappers in WQApps.m) and return a clear message until then.
//

#import "WQMCPServer.h"
#import "WQAccess.h"
#import "WQLaunchServices.h"
#import "WQApps.h"
#import "WQUI.h"
#import <Security/Security.h>
#import <sys/socket.h>
#import <sys/stat.h>
#import <netinet/in.h>
#import <arpa/inet.h>
#import <unistd.h>
#import <errno.h>
#import <string.h>
#import <stdlib.h>

NSString *const WQMCPPort = @"18765";
NSString *const WQMCPServerChangedNotification = @"WQMCPServerChangedNotification";

static const NSUInteger kWQMCPMaxReadBytes = 262144;      // 256 KiB
static const NSUInteger kWQMCPMaxSearchNodes = 2000;
static const NSTimeInterval kWQMCPSearchSeconds = 2.0;
static const NSTimeInterval kWQMCPPlanTTL = 120.0;

#pragma mark - Plan / Cursor models

@interface WQMCPPlan : NSObject
@property (nonatomic, copy) NSString *token;
@property (nonatomic, copy) NSString *operation;      // write/delete/rename/mkdir/move
@property (nonatomic, copy, nullable) NSString *path;
@property (nonatomic, copy, nullable) NSString *renamedName;
@property (nonatomic, copy, nullable) NSString *destDir;
@property (nonatomic, copy, nullable) NSString *bundleID;
@property (nonatomic, copy, nullable) NSString *backupName;
@property (nonatomic, assign) BOOL safetyBackup;
@property (nonatomic, strong, nullable) NSData *data;
@property (nonatomic, strong, nullable) NSDictionary<NSString *, NSNumber *> *identity;
@property (nonatomic, assign) NSTimeInterval expires;
@end
@implementation WQMCPPlan
@end

#pragma mark - WQMCPServer

@interface WQMCPServer () {
    NSString *_secret;   // custom getter/setter below, so no auto-synthesized ivar
}
@property (atomic, assign, readwrite, getter=isRunning) BOOL running;
@property (nonatomic, assign) int listenFD;
@property (nonatomic, strong) dispatch_queue_t stateQueue;   // guards plans/searches
@property (nonatomic, strong) NSMutableDictionary<NSString *, WQMCPPlan *> *plans;
@property (nonatomic, strong) NSMutableDictionary<NSString *, NSMutableDictionary *> *searches;
@property (nonatomic, weak) UITextView *resultView;
@property (nonatomic, weak) UIViewController *hostVC;
@end

@implementation WQMCPServer

+ (instancetype)shared {
    static WQMCPServer *shared;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ shared = [WQMCPServer new]; });
    return shared;
}

- (instancetype)init {
    if ((self = [super init])) {
        _listenFD = -1;
        _stateQueue = dispatch_queue_create("com.wqfiles.mcp.state", DISPATCH_QUEUE_SERIAL);
        _plans = [NSMutableDictionary dictionary];
        _searches = [NSMutableDictionary dictionary];
    }
    return self;
}

#pragma mark Token

- (NSString *)tokenPath {
    NSArray<NSString *> *dirs = NSSearchPathForDirectoriesInDomains(NSApplicationSupportDirectory,
                                                                   NSUserDomainMask, YES);
    NSString *base = dirs.firstObject ?: NSTemporaryDirectory();
    return [[base stringByAppendingPathComponent:@"WQMCP"] stringByAppendingPathComponent:@"token"];
}

- (NSString *)loadOrCreateSecret {
    NSString *path = [self tokenPath];
    NSFileManager *fm = NSFileManager.defaultManager;
    NSString *existing = [NSString stringWithContentsOfFile:path encoding:NSUTF8StringEncoding error:NULL];
    existing = [existing stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if (existing.length >= 16) return existing;
    uint8_t rnd[24];
    (void)SecRandomCopyBytes(kSecRandomDefault, sizeof(rnd), rnd);
    NSMutableString *tok = [NSMutableString stringWithCapacity:sizeof(rnd) * 2];
    for (size_t i = 0; i < sizeof(rnd); i++) [tok appendFormat:@"%02x", rnd[i]];
    [fm createDirectoryAtPath:[path stringByDeletingLastPathComponent]
  withIntermediateDirectories:YES attributes:nil error:NULL];
    [tok writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:NULL];
    [fm setAttributes:@{NSFileProtectionKey: NSFileProtectionComplete} ofItemAtPath:path error:NULL];
    return tok;
}

- (NSString *)secret {
    @synchronized (self) {
        if (!_secret) _secret = [self loadOrCreateSecret];
        return _secret;
    }
}

- (void)setSecret:(NSString *)secret { @synchronized (self) { _secret = [secret copy]; } }

#pragma mark Lifecycle

- (void)start {
    @synchronized (self) {
        if (self.running) return;
        int fd = socket(AF_INET, SOCK_STREAM, 0);
        if (fd < 0) { wq_log(@"[mcp] socket() failed: %s", strerror(errno)); return; }
        int one = 1;
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &one, sizeof(one));
        struct sockaddr_in addr;
        memset(&addr, 0, sizeof(addr));
        addr.sin_family = AF_INET;
        addr.sin_port = htons((uint16_t)WQMCPPort.integerValue);
        addr.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
        if (bind(fd, (struct sockaddr *)&addr, sizeof(addr)) != 0) {
            wq_log(@"[mcp] Port %@ unavailable: %s", WQMCPPort, strerror(errno));
            close(fd);
            return;
        }
        if (listen(fd, 16) != 0) { wq_log(@"[mcp] listen() failed: %s", strerror(errno)); close(fd); return; }
        self.listenFD = fd;
        self.running = YES;
        wq_log(@"[mcp] Listening on 127.0.0.1:%@ (iOS may suspend in background)", WQMCPPort);
        (void)self.secret; // ensure token exists
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{ [self acceptLoop]; });
    }
    [[NSNotificationCenter defaultCenter] postNotificationName:WQMCPServerChangedNotification object:self];
}

- (void)stop {
    @synchronized (self) {
        if (!self.running) return;
        self.running = NO;
        if (self.listenFD >= 0) { shutdown(self.listenFD, SHUT_RDWR); close(self.listenFD); self.listenFD = -1; }
        wq_log(@"[mcp] Stopped");
    }
    [[NSNotificationCenter defaultCenter] postNotificationName:WQMCPServerChangedNotification object:self];
}

- (void)acceptLoop {
    while (self.running) {
        int cfd = accept(self.listenFD, NULL, NULL);
        if (cfd < 0) {
            if (!self.running) break;
            if (errno == EINTR) continue;
            break;
        }
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_DEFAULT, 0), ^{ [self handleSocket:cfd]; });
    }
}

#pragma mark HTTP

- (void)handleSocket:(int)fd {
    @autoreleasepool {
        NSMutableData *buffer = [NSMutableData data];
        uint8_t chunk[4096];
        NSUInteger headerEnd = NSNotFound;
        long contentLength = 0;
        // Read headers (bounded).
        while (buffer.length < 65536) {
            ssize_t n = recv(fd, chunk, sizeof(chunk), 0);
            if (n <= 0) { close(fd); return; }
            [buffer appendBytes:chunk length:(NSUInteger)n];
            NSRange hdr = [buffer rangeOfData:[@"\r\n\r\n" dataUsingEncoding:NSUTF8StringEncoding]
                                      options:0 range:NSMakeRange(0, buffer.length)];
            if (hdr.location != NSNotFound) { headerEnd = hdr.location + hdr.length; break; }
        }
        if (headerEnd == NSNotFound) { close(fd); return; }

        NSString *head = [[NSString alloc] initWithData:[buffer subdataWithRange:NSMakeRange(0, headerEnd)]
                                               encoding:NSUTF8StringEncoding];
        for (NSString *line in [head componentsSeparatedByString:@"\r\n"]) {
            NSString *lower = line.lowercaseString;
            if ([lower hasPrefix:@"content-length:"]) {
                contentLength = [[line substringFromIndex:@"content-length:".length]
                                 stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet].integerValue;
            }
        }
        // Read body.
        NSMutableData *body = [NSMutableData dataWithData:[buffer subdataWithRange:NSMakeRange(headerEnd, buffer.length - headerEnd)]];
        while ((long)body.length < contentLength) {
            ssize_t n = recv(fd, chunk, sizeof(chunk), 0);
            if (n <= 0) break;
            [body appendBytes:chunk length:(NSUInteger)n];
        }

        // Auth: require Bearer token.
        BOOL authorized = NO;
        for (NSString *line in [head componentsSeparatedByString:@"\r\n"]) {
            if ([line.lowercaseString hasPrefix:@"authorization:"]) {
                NSString *val = [[line substringFromIndex:@"authorization:".length]
                                 stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
                NSString *expect = [@"Bearer " stringByAppendingString:self.secret ?: @""];
                authorized = [val isEqualToString:expect];
            }
        }
        if (!authorized) {
            [self reply:fd code:401 object:@{@"error": @"unauthorized", @"message": @"Missing or invalid bearer token"}];
            close(fd);
            return;
        }

        NSData *resp = nil;
        @try {
            resp = [self rpcRespondToBody:body];
        } @catch (NSException *e) {
            resp = [NSJSONSerialization dataWithJSONObject:@{@"jsonrpc": @"2.0", @"id": NSNull.null,
                                                             @"error": @{@"code": @-32603, @"message": e.reason ?: @"internal error"}}
                                                  options:0 error:NULL];
        }
        if (resp) {
            [self reply:fd code:200 objectData:resp];
        }
        // Notifications (no id) produce no response.
        close(fd);
    }
}

- (void)reply:(int)fd code:(int)code object:(id)object {
    NSData *data = [NSJSONSerialization dataWithJSONObject:object options:0 error:NULL];
    [self reply:fd code:code objectData:data ?: [NSData data]];
}

- (void)reply:(int)fd code:(int)code objectData:(NSData *)body {
    NSString *status = code == 200 ? @"OK" : code == 401 ? @"Unauthorized" : @"Error";
    NSMutableString *head = [NSMutableString stringWithFormat:
        @"HTTP/1.1 %d %@\r\nContent-Type: application/json\r\nContent-Length: %lu\r\nConnection: close\r\n",
        code, status, (unsigned long)body.length];
    if (code == 401) [head appendString:@"WWW-Authenticate: Bearer\r\n"];
    [head appendString:@"\r\n"];
    NSMutableData *out = [[head dataUsingEncoding:NSUTF8StringEncoding] mutableCopy];
    [out appendData:body];
    ssize_t off = 0;
    const uint8_t *p = out.bytes;
    while (off < (ssize_t)out.length) {
        ssize_t n = send(fd, p + off, out.length - (NSUInteger)off, 0);
        if (n <= 0) break;
        off += n;
    }
}

#pragma mark JSON-RPC

- (nullable NSData *)rpcRespondToBody:(NSData *)body {
    if (body.length == 0) return nil;
    id obj = [NSJSONSerialization JSONObjectWithData:body options:0 error:NULL];
    if (![obj isKindOfClass:NSDictionary.class]) {
        return [self rpcResult:nil error:@{@"code": @-32700, @"message": @"parse error"}];
    }
    NSDictionary *req = obj;
    id reqId = req[@"id"];
    NSString *method = req[@"method"];
    if (![method isKindOfClass:NSString.class]) {
        return [self rpcResult:reqId error:@{@"code": @-32600, @"message": @"invalid request"}];
    }
    // Notifications: no response.
    if (!reqId) {
        if ([method isEqualToString:@"notifications/initialized"]) return nil;
        return nil;
    }
    if ([method isEqualToString:@"initialize"]) {
        return [self rpcResult:reqId result:@{
            @"protocolVersion": @"2025-06-18",
            @"capabilities": @{@"tools": @{}},
            @"serverInfo": @{@"name": @"WQFiles MCP", @"version": @"0.9.19-mcp1"},
            @"instructions": @"Read/write access. No background keepalive. Confirm plans before commit.",
        }];
    }
    if ([method isEqualToString:@"ping"]) {
        return [self rpcResult:reqId result:@{}];
    }
    if ([method isEqualToString:@"tools/list"]) {
        return [self rpcResult:reqId result:@{@"tools": [self toolSchemas]}];
    }
    if ([method isEqualToString:@"tools/call"]) {
        NSDictionary *params = req[@"params"];
        NSString *name = params[@"name"];
        NSDictionary *arguments = params[@"arguments"];
        if (![name isKindOfClass:NSString.class]) {
            return [self rpcResult:reqId error:@{@"code": @-32602, @"message": @"Unknown tool"}];
        }
        @try {
            id result = [self callTool:name arguments:[arguments isKindOfClass:NSDictionary.class] ? arguments : @{}];
            return [self rpcResult:reqId result:result];
        } @catch (NSException *e) {
            return [self rpcResult:reqId result:@{@"isError": @YES,
                @"content": @[@{@"type": @"text", @"text": e.reason ?: @"tool error"}]}];
        }
    }
    return [self rpcResult:reqId error:@{@"code": @-32601, @"message": @"method not found"}];
}

- (NSData *)rpcResult:(nullable id)reqId result:(id)result {
    NSDictionary *resp = @{@"jsonrpc": @"2.0", @"id": reqId ?: NSNull.null, @"result": result};
    return [NSJSONSerialization dataWithJSONObject:resp options:0 error:NULL];
}

- (NSData *)rpcResult:(nullable id)reqId error:(NSDictionary *)error {
    NSDictionary *resp = @{@"jsonrpc": @"2.0", @"id": reqId ?: NSNull.null, @"error": error};
    return [NSJSONSerialization dataWithJSONObject:resp options:0 error:NULL];
}

#pragma mark Tool schemas

- (NSArray<NSDictionary *> *)toolSchemas {
    NSDictionary *(^str)(NSString *, NSString *) = ^NSDictionary *(NSString *desc, NSString *def) {
        return @{@"type": @"string", @"description": desc, @"default": def};
    };
    return @[
        @{@"name": @"search", @"description": @"Filename substring search (case-insensitive, no file contents). Initial path/query; continue using cursor only. Bounded 2000 nodes/2 seconds per page; cursor expires in 120 seconds.",
          @"inputSchema": @{@"type": @"object", @"properties": @{
              @"path": str(@"Absolute directory to search from.", @""),
              @"query": str(@"1..256 character substring.", @""),
              @"cursor": str(@"Continuation cursor from a previous page.", @""),
              @"limit": @{@"type": @"integer", @"description": @"Max results this page."}},
              @"required": @[@"path", @"query"]}},
        @{@"name": @"read", @"description": @"Read at most 262144 bytes. encoding utf8 or base64; byte offset, not character offset.",
          @"inputSchema": @{@"type": @"object", @"properties": @{
              @"path": str(@"Absolute file path.", @""),
              @"offset": @{@"type": @"integer", @"description": @"Byte offset."},
              @"length": @{@"type": @"integer", @"description": @"Byte count (<=262144)."},
              @"encoding": str(@"utf8 (default) or base64.", @"utf8")},
              @"required": @[@"path"]}},
        @{@"name": @"plan", @"description": @"Stage a mutation WITHOUT executing it. Show the exact returned targets, sizes and irreversible items to the user; obtain explicit confirmation before commit. Close target app manually. Expires after 120 seconds; one use.",
          @"inputSchema": @{@"type": @"object", @"properties": @{
              @"operation": str(@"write | delete | rename | mkdir | move | app_backup | app_clear | app_restore.", @""),
              @"path": str(@"Target absolute path (not needed for app_* operations).", @""),
              @"bundleID": str(@"app_*: bundle id of the target app (e.g. com.tencent.xin).", @""),
              @"backup": str(@"app_restore: backup folder name (optional; newest when omitted).", @""),
              @"safetyBackup": @{@"type": @"boolean", @"description": @"app_clear: make a safety backup first (default true)."},
              @"newName": str(@"rename: new base name.", @""),
              @"destDir": str(@"move: destination directory.", @""),
              @"dataBase64": str(@"write: file contents, base64.", @"")},
              @"required": @[@"operation"]}},
        @{@"name": @"commit", @"description": @"Execute an unchanged, unexpired plan ONLY after the user explicitly confirmed its targets and risks. The confirmation token is consumed even on failure; no auto retry.",
          @"inputSchema": @{@"type": @"object", @"properties": @{@"token": str(@"Token returned by plan.", @"")},
              @"required": @[@"token"]}},
        @{@"name": @"backups", @"description": @"List validated upstream app backups for an app container.",
          @"inputSchema": @{@"type": @"object", @"properties": @{
              @"bundleID": str(@"App bundle id (optional).", @""),
              @"container": str(@"App data container path (optional).", @"")},
              @"required": @[]}},
    ];
}

#pragma mark Tool dispatch

- (id)callTool:(NSString *)name arguments:(NSDictionary *)args {
    if ([name isEqualToString:@"search"]) return [self toolSearch:args];
    if ([name isEqualToString:@"read"]) return [self toolRead:args];
    if ([name isEqualToString:@"plan"]) return [self toolPlan:args];
    if ([name isEqualToString:@"commit"]) return [self toolCommit:args];
    if ([name isEqualToString:@"backups"]) return [self toolBackups:args];
    @throw [NSException exceptionWithName:@"WQMCP" reason:@"Unknown tool" userInfo:nil];
}

- (id)textResult:(NSString *)text isError:(BOOL)isError {
    return @{@"content": @[@{@"type": @"text", @"text": text ?: @""}], @"isError": @(isError)};
}

- (NSString *)requiredString:(NSDictionary *)args key:(NSString *)key {
    id v = args[key];
    if (![v isKindOfClass:NSString.class] || [(NSString *)v length] == 0)
        @throw [NSException exceptionWithName:@"WQMCP" reason:[NSString stringWithFormat:@"Missing required argument: %@", key] userInfo:nil];
    return v;
}

#pragma mark search

- (id)toolSearch:(NSDictionary *)args {
    NSString *path = [self requiredString:args key:@"path"];
    NSString *query = [self requiredString:args key:@"query"];
    if (query.length > 256) @throw [NSException exceptionWithName:@"WQMCP" reason:@"Search requires path and a 1..256 character query" userInfo:nil];
    NSUInteger limit = [(args[@"limit"] ?: @200) unsignedIntegerValue];
    if (limit == 0) limit = 200;
    NSString *cursor = [args[@"cursor"] isKindOfClass:NSString.class] ? args[@"cursor"] : nil;

    __block NSMutableDictionary *state = nil;
    __block NSDictionary *outPage = nil;
    dispatch_sync(self.stateQueue, ^{
        if (cursor) {
            state = self.searches[cursor];
            [self.searches removeObjectForKey:cursor];
            if (!state) return;
        } else {
            // Container roots aren't listable directly (sandbox); enumerate the
            // real per-app containers via LaunchServices, like the WQ Files UI.
            NSArray<NSString *> *containerRoots = @[
                @"/var/mobile/Containers/Data/Application",
                @"/var/mobile/Containers/Shared/AppGroup",
                @"/var/mobile/Containers/Data/PluginKitPlugin",
                @"/var/mobile/Containers/Data/InternalDaemon",
            ];
            NSMutableArray<NSString *> *roots = [NSMutableArray array];
            if ([containerRoots containsObject:path]) {
                NSArray<NSString *> *real = wq_ls_container_paths(nil) ?: @[];
                if (real.count) [roots addObjectsFromArray:real];
                else [roots addObject:path];
            } else {
                [roots addObject:path];
            }
            state = [@{
                @"pending": roots,
                @"query": query.lowercaseString,
                @"nodes": @0,
                @"matches": [NSMutableArray array],
            } mutableCopy];
        }
        NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:kWQMCPSearchSeconds];
        NSMutableArray *pending = state[@"pending"];
        NSMutableArray *matches = state[@"matches"];
        NSUInteger nodes = [state[@"nodes"] unsignedIntegerValue];
        while (pending.count > 0 && nodes < kWQMCPMaxSearchNodes &&
               [deadline timeIntervalSinceNow] > 0 && matches.count < limit) {
            NSString *dir = pending.lastObject;
            [pending removeLastObject];
            wq_grant(dir);   // worse_query: allow streaming this directory before listing
            NSArray<NSString *> *entries = wq_list(dir, NULL) ?: @[];
            for (NSString *name in entries) {
                nodes++;
                NSString *full = [dir stringByAppendingPathComponent:name];
                BOOL isDir = NO;
                BOOL exists = [NSFileManager.defaultManager fileExistsAtPath:full isDirectory:&isDir];
                if (!exists) continue;
                if ([name.lowercaseString containsString:state[@"query"]]) {
                    [matches addObject:@{@"path": full, @"isDirectory": @(isDir)}];
                    if (matches.count >= limit) break;
                }
                if (isDir) [pending addObject:full];
            }
        }
        state[@"nodes"] = @(nodes);
        // Snapshot this page and schedule the next one atomically, on the queue.
        NSArray *page = [matches copy];
        NSString *nextCursor = nil;
        if (pending.count > 0) {
            nextCursor = [self newToken];
            state[@"expires"] = @([[NSDate date] timeIntervalSince1970] + 120.0);
            [matches removeAllObjects];
            self.searches[nextCursor] = state;
        }
        outPage = @{@"results": page, @"cursor": nextCursor ?: NSNull.null, @"nodesScanned": @(nodes)};
    });

    if (!outPage) return [self textResult:@"Unknown, consumed or expired search cursor; restart search" isError:YES];
    return [self textResult:[self jsonString:outPage] isError:NO];
}

#pragma mark read

- (id)toolRead:(NSDictionary *)args {
    NSString *path = [self requiredString:args key:@"path"];
    unsigned long long offset = [args[@"offset"] ?: @0 unsignedLongLongValue];
    NSUInteger length = [args[@"length"] ?: @4096 unsignedIntegerValue];
    if (length == 0) length = 4096;
    if (length > kWQMCPMaxReadBytes) length = kWQMCPMaxReadBytes;
    NSString *encoding = [args[@"encoding"] isKindOfClass:NSString.class] ? args[@"encoding"] : @"utf8";
    NSString *err = nil;
    NSData *data = wq_read_range(path, offset, length, &err);
    if (!data) return [self textResult:err ?: @"Cannot read this file" isError:YES];
    NSString *payload;
    if ([encoding.lowercaseString isEqualToString:@"base64"]) {
        payload = [data base64EncodedStringWithOptions:0];
    } else {
        payload = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
        if (!payload) payload = [data base64EncodedStringWithOptions:0];
    }
    return [self textResult:[self jsonString:@{@"path": path, @"offset": @(offset),
                                               @"bytesRead": @(data.length), @"encoding": encoding,
                                               @"content": payload}] isError:NO];
}

#pragma mark plan

- (id)toolPlan:(NSDictionary *)args {
    NSString *op = [self requiredString:args key:@"operation"];
    BOOL isApp = [op hasPrefix:@"app_"];
    NSString *path = isApp ? nil : [self requiredString:args key:@"path"];
    if (!isApp && (wq_is_protected_folder(path) || wq_is_backup_storage_path(path))) {
        return [self textResult:@"Protected/invalid mutation path (WQFiles sandbox, backup stores and broad ancestors are protected)" isError:YES];
    }
    WQMCPPlan *plan = [WQMCPPlan new];
    plan.token = [self newToken];
    plan.operation = op;
    plan.path = path;
    plan.expires = [[NSDate date] timeIntervalSince1970] + kWQMCPPlanTTL;
    if (path) plan.identity = wq_item_identity(path);

    NSString *irreversible = @"";
    unsigned long long size = 0;
    struct stat st;
    BOOL exists = (path && wq_stat(path, &st) && S_ISREG(st.st_mode));

    if ([op isEqualToString:@"write"]) {
        NSString *b64 = [self requiredString:args key:@"dataBase64"];
        NSData *data = [[NSData alloc] initWithBase64EncodedString:b64 options:0];
        if (!data) return [self textResult:@"data required" isError:YES];
        plan.data = data; size = data.length;
        irreversible = exists ? @"Overwrites the current file; a backup is kept in Backups." : @"Creates a new file.";
    } else if ([op isEqualToString:@"delete"]) {
        irreversible = @"Moves the file to Backups (restorable).";
    } else if ([op isEqualToString:@"rename"]) {
        plan.renamedName = [self requiredString:args key:@"newName"];
        if ([plan.renamedName containsString:@"/"]) return [self textResult:@"newName must be a bare name" isError:YES];
        irreversible = @"Renames in place; no safety copy.";
    } else if ([op isEqualToString:@"mkdir"]) {
        irreversible = @"Creates a directory.";
    } else if ([op isEqualToString:@"move"]) {
        plan.destDir = [self requiredString:args key:@"destDir"];
        irreversible = @"Moves across folders; no safety copy.";
    } else if ([op isEqualToString:@"app_backup"] || [op isEqualToString:@"app_clear"] || [op isEqualToString:@"app_restore"]) {
        plan.bundleID = [self requiredString:args key:@"bundleID"];
        plan.backupName = [args[@"backup"] isKindOfClass:NSString.class] ? args[@"backup"] : nil;
        plan.safetyBackup = args[@"safetyBackup"] ? [args[@"safetyBackup"] boolValue] : YES;
        if ([op isEqualToString:@"app_clear"]) {
            irreversible = @"Deletes the app's Documents, Library and tmp (like a fresh install). Safety backup first; logins and offline data are lost.";
        } else if ([op isEqualToString:@"app_restore"]) {
            irreversible = @"Replaces the app's Documents and Library from a backup. Current data is safety-backed up first.";
        } else {
            irreversible = @"Creates a verified backup of the app's Documents and Library. No data is changed.";
        }
    } else {
        return [self textResult:@"Unknown operation" isError:YES];
    }

    dispatch_async(self.stateQueue, ^{ self.plans[plan.token] = plan; });
    return [self textResult:[self jsonString:@{
        @"token": plan.token, @"operation": op, @"path": path,
        @"exists": @(exists), @"size": @(size),
        @"irreversible": irreversible,
        @"expiresIn": @((NSInteger)kWQMCPPlanTTL),
        @"note": @"Show this to the user. Call commit with the token only after explicit confirmation.",
    }] isError:NO];
}

#pragma mark commit

- (id)toolCommit:(NSDictionary *)args {
    NSString *token = [self requiredString:args key:@"token"];
    __block WQMCPPlan *plan = nil;
    dispatch_sync(self.stateQueue, ^{
        plan = self.plans[token];
        [self.plans removeObjectForKey:token];   // one use, even on failure
    });
    if (!plan || plan.expires < [[NSDate date] timeIntervalSince1970]) {
        return [self textResult:@"Unknown, expired or already consumed confirmation token" isError:YES];
    }
    // Re-check identity for existing targets.
    if (plan.path) {
        NSDictionary *now = wq_item_identity(plan.path);
        if (plan.identity && now && ![plan.identity isEqualToDictionary:now]) {
            return [self textResult:@"Target changed since plan; create a new plan and ask for confirmation again" isError:YES];
        }
    }
    if ([plan.operation hasPrefix:@"app_"]) {
        NSString *appErr = nil;
        NSDictionary *res = nil;
        if ([plan.operation isEqualToString:@"app_backup"]) res = WQMCPAppBackup(plan.bundleID, &appErr);
        else if ([plan.operation isEqualToString:@"app_clear"]) res = WQMCPAppClear(plan.bundleID, plan.safetyBackup, &appErr);
        else res = WQMCPAppRestore(plan.bundleID, plan.backupName, &appErr);
        if (!res) return [self textResult:(appErr ?: @"App operation failed") isError:YES];
        return [self textResult:[self jsonString:res] isError:NO];
    }
    NSString *err = nil;
    BOOL ok = NO;
    if ([plan.operation isEqualToString:@"write"]) {
        // New file -> create (O_CREAT); existing file -> overwrite in place.
        if (plan.identity) ok = wq_write(plan.path, plan.data ?: [NSData data], &err);
        else ok = wq_create_file(plan.path, plan.data ?: [NSData data], &err);
    } else if ([plan.operation isEqualToString:@"delete"]) {
        ok = wq_delete(plan.path, &err);
    } else if ([plan.operation isEqualToString:@"rename"]) {
        ok = wq_rename(plan.path, plan.renamedName ?: @"", &err);
    } else if ([plan.operation isEqualToString:@"mkdir"]) {
        ok = wq_create_dir(plan.path, &err);
    } else if ([plan.operation isEqualToString:@"move"]) {
        ok = wq_move(plan.path, plan.destDir ?: @"", &err);
    }
    return [self textResult:[self jsonString:@{@"ok": @(ok), @"operation": plan.operation,
                                               @"path": plan.path, @"error": err ?: NSNull.null}]
                    isError:!ok];
}

#pragma mark backups

- (id)toolBackups:(NSDictionary *)args {
    NSString *root = wq_app_backup_root();
    NSMutableArray *units = [NSMutableArray array];
    NSFileManager *fm = NSFileManager.defaultManager;
    NSArray<NSString *> *apps = [fm contentsOfDirectoryAtPath:root error:NULL] ?: @[];
    for (NSString *appDir in apps) {
        NSString *full = [root stringByAppendingPathComponent:appDir];
        NSArray<NSString *> *parts = [fm contentsOfDirectoryAtPath:full error:NULL] ?: @[];
        [units addObject:@{@"app": appDir, @"backups": parts}];
    }
    return [self textResult:[self jsonString:@{@"root": root, @"units": units}] isError:NO];
}

#pragma mark helpers

- (NSString *)newToken {
    uint8_t rnd[16];
    if (SecRandomCopyBytes(kSecRandomDefault, sizeof(rnd), rnd) != 0) {
        arc4random_buf(rnd, sizeof(rnd));
    }
    NSMutableString *s = [NSMutableString stringWithCapacity:sizeof(rnd) * 2];
    for (size_t i = 0; i < sizeof(rnd); i++) [s appendFormat:@"%02x", rnd[i]];
    return s;
}

- (NSString *)jsonString:(id)obj {
    NSData *d = [NSJSONSerialization dataWithJSONObject:obj options:0 error:NULL];
    return d ? [[NSString alloc] initWithData:d encoding:NSUTF8StringEncoding] : @"{}";
}

#pragma mark UI

- (UIViewController *)controlsViewController {
    UIViewController *vc = [UIViewController new];
    vc.title = @"MCP 服务";
    vc.view.backgroundColor = UIColor.systemBackgroundColor;

    UITextView *tv = [UITextView new];
    tv.editable = NO;
    tv.selectable = YES;
    tv.font = [UIFont monospacedSystemFontOfSize:13 weight:UIFontWeightRegular];
    tv.translatesAutoresizingMaskIntoConstraints = NO;
    tv.backgroundColor = UIColor.secondarySystemBackgroundColor;
    tv.layer.cornerRadius = 12;
    tv.textContainerInset = UIEdgeInsetsMake(12, 12, 12, 12);
    [vc.view addSubview:tv];
    self.resultView = tv;
    self.hostVC = vc;

    UIButton *copy = [UIButton buttonWithType:UIButtonTypeSystem];
    [copy setTitle:@"复制令牌" forState:UIControlStateNormal];
    [copy addTarget:self action:@selector(copySecretButton:) forControlEvents:UIControlEventTouchUpInside];
    UIButton *test = [UIButton buttonWithType:UIButtonTypeSystem];
    [test setTitle:@"自检" forState:UIControlStateNormal];
    [test addTarget:self action:@selector(runSelfTest:) forControlEvents:UIControlEventTouchUpInside];
    for (UIButton *b in @[copy, test]) {
        b.titleLabel.font = [UIFont systemFontOfSize:16 weight:UIFontWeightSemibold];
        b.backgroundColor = UIColor.tertiarySystemFillColor;
        b.layer.cornerRadius = 12;
    }
    UIStackView *row = [[UIStackView alloc] initWithArrangedSubviews:@[copy, test]];
    row.axis = UILayoutConstraintAxisHorizontal;
    row.distribution = UIStackViewDistributionFillEqually;
    row.spacing = 12;
    row.translatesAutoresizingMaskIntoConstraints = NO;
    [vc.view addSubview:row];

    [NSLayoutConstraint activateConstraints:@[
        [tv.topAnchor constraintEqualToAnchor:vc.view.safeAreaLayoutGuide.topAnchor constant:12],
        [tv.leadingAnchor constraintEqualToAnchor:vc.view.leadingAnchor constant:16],
        [tv.trailingAnchor constraintEqualToAnchor:vc.view.trailingAnchor constant:-16],
        [row.topAnchor constraintEqualToAnchor:tv.bottomAnchor constant:12],
        [row.leadingAnchor constraintEqualToAnchor:tv.leadingAnchor],
        [row.trailingAnchor constraintEqualToAnchor:tv.trailingAnchor],
        [row.heightAnchor constraintEqualToConstant:44],
    ]];

    __weak typeof(self) weakSelf = self;
    void (^refresh)(void) = ^{
        tv.text = [NSString stringWithFormat:
            @"%@\n\n地址\nhttp://127.0.0.1:%@/mcp\n\n令牌\n%@\n\n把 MCP 客户端指向上面地址，加请求头\nAuthorization: Bearer <令牌>\n\n点「自检」会在进程内把 5 个工具各跑一遍。",
            weakSelf.isRunning ? @"● 运行中" : @"○ 已停止", WQMCPPort, weakSelf.secret ?: @""];
    };
    refresh();
    [[NSNotificationCenter defaultCenter] addObserverForName:WQMCPServerChangedNotification object:self
                                                      queue:NSOperationQueue.mainQueue usingBlock:^(__unused NSNotification *n) {
        refresh();
        vc.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc]
            initWithTitle:(weakSelf.isRunning ? @"停止" : @"启动")
                    style:wq_primary_button_style()
                   target:weakSelf action:@selector(toggleFromControls)];
    }];
    vc.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc]
        initWithTitle:(self.isRunning ? @"停止" : @"启动")
                style:wq_primary_button_style()
               target:self action:@selector(toggleFromControls)];
    // Run once automatically so the page shows the result without a tap.
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{ [self runSelfTest:test]; });
    return vc;
}

- (void)copySecretButton:(__unused UIButton *)sender {
    UIPasteboard.generalPasteboard.string = self.secret ?: @"";
    UIImpactFeedbackGenerator *fb = [[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleMedium];
    [fb impactOccurred];
}

- (void)runSelfTest:(UIButton *)sender
{
    sender.enabled = NO;
    [sender setTitle:@"测试中…" forState:UIControlStateNormal];
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSMutableString *r = [NSMutableString string];
        NSString *err = nil; BOOL ok = NO;
        NSString *dir = [self.tokenPath stringByDeletingLastPathComponent];
        NSString *p1 = [dir stringByAppendingPathComponent:@"selftest_a.txt"];
        NSString *p2 = [dir stringByAppendingPathComponent:@"selftest_b.txt"];
        NSString *sub = [dir stringByAppendingPathComponent:@"selftest_dir"];
        NSString *p3 = [sub stringByAppendingPathComponent:@"selftest_b.txt"];
        NSData *payload = [@"hello" dataUsingEncoding:NSUTF8StringEncoding];
        @try {
            ok = wq_create_file(p1, payload, &err);
            [r appendFormat:@"create %@  %@\n", ok ? @"PASS" : @"FAIL", err ?: @""]; err = nil;
            NSData *d = wq_read(p1, 1024, &err);
            [r appendFormat:@"read   %@  %lu bytes %@\n", d.length ? @"PASS" : @"FAIL", (unsigned long)d.length, err ?: @""]; err = nil;
            ok = wq_rename(p1, @"selftest_b.txt", &err);
            [r appendFormat:@"rename %@  %@\n", ok ? @"PASS" : @"FAIL", err ?: @""]; err = nil;
            ok = wq_create_dir(sub, &err);
            [r appendFormat:@"mkdir  %@  %@\n", ok ? @"PASS" : @"FAIL", err ?: @""]; err = nil;
            ok = wq_move(p2, sub, &err);
            [r appendFormat:@"move   %@  %@\n", ok ? @"PASS" : @"FAIL", err ?: @""]; err = nil;
            NSData *d2 = wq_read(p3, 64, &err);
            [r appendFormat:@"read2  %@  %lu bytes %@\n", d2.length ? @"PASS" : @"FAIL", (unsigned long)d2.length, err ?: @""]; err = nil;
            ok = wq_delete(p3, &err);
            [r appendFormat:@"delete %@  %@\n", ok ? @"PASS" : @"FAIL", err ?: @""]; err = nil;

            NSArray<NSString *> *cs = wq_ls_container_paths(nil) ?: @[];
            NSUInteger listed = 0;
            for (NSString *c in cs) {
                if ([c isEqualToString:[dir stringByDeletingLastPathComponent]]) continue;
                wq_grant(c);
                if (wq_list(c, NULL)) { listed++; if (listed >= 3) break; }
            }
            [r appendFormat:@"跨容器打开 %lu/%lu（共发现 %lu 个容器）\n",
                (unsigned long)listed, (unsigned long)MIN((NSUInteger)3, cs.count), (unsigned long)cs.count];

            NSString *backupRoot = wq_app_backup_root();
            NSArray *units = backupRoot ? ([NSFileManager.defaultManager contentsOfDirectoryAtPath:backupRoot error:NULL] ?: @[]) : @[];
            [r appendFormat:@"备份根 %@（%lu 个 App）\n", backupRoot ?: @"(nil)", (unsigned long)units.count];
        } @catch (NSException *e) {
            [r appendFormat:@"\nEXCEPTION %@: %@\n", e.name, e.reason ?: @""];
        }
        [r appendFormat:@"\n服务 %@  ·  http://127.0.0.1:%@/mcp", self.isRunning ? @"运行中" : @"已停止", WQMCPPort];
        dispatch_async(dispatch_get_main_queue(), ^{
            sender.enabled = YES;
            [sender setTitle:@"自检" forState:UIControlStateNormal];
            UITextView *tv = self.resultView;
            if (tv) tv.text = r;
            else {
                UIAlertController *a = [UIAlertController alertControllerWithTitle:@"MCP 自检" message:r preferredStyle:UIAlertControllerStyleAlert];
                [a addAction:[UIAlertAction actionWithTitle:@"好" style:UIAlertActionStyleCancel handler:nil]];
                [self.hostVC presentViewController:a animated:YES completion:nil];
            }
        });
    });
}

- (void)toggleFromControls {
    if (self.isRunning) [self stop]; else [self start];
}

- (void)copySecret:(UILongPressGestureRecognizer *)g {
    if (g.state != UIGestureRecognizerStateBegan) return;
    UIPasteboard.generalPasteboard.string = self.secret ?: @"";
    UIImpactFeedbackGenerator *fb = [[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleMedium];
    [fb impactOccurred];
}

@end

//
//  WQMCPServer.h
//  WQ Files — MCP (Model Context Protocol) server over localhost HTTP.
//  GPL-3.0-or-later.
//
//  Exposes the app's file / container tools to an MCP client on
//  http://127.0.0.1:18765/mcp (Streamable HTTP, JSON-RPC, Bearer auth).
//  Tools: search, read, plan, commit, backups. Mutations go plan -> human
//  approval -> commit; a plan is one-use and expires after 120 seconds.
//

#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

extern NSString *const WQMCPPort;          // @"18765"
extern NSString *const WQMCPServerChangedNotification;

@interface WQMCPServer : NSObject

+ (instancetype)shared;

// YES while the listener is up.
@property (atomic, readonly, getter=isRunning) BOOL running;

// Bearer token. Loaded from (and persisted to) the token file on first use.
@property (atomic, copy, nullable) NSString *secret;

// Path of the persisted bearer token.
- (NSString *)tokenPath;

// Bind 127.0.0.1:18765 and serve MCP until -stop. Idempotent.
- (void)start;
- (void)stop;

// Settings entry point: a view controller showing status, the URL, and a
// "Copy Bearer Token" / start-stop control.
- (UIViewController *)controlsViewController;

@end

NS_ASSUME_NONNULL_END

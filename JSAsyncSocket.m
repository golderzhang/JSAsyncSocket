//
//  JSAsyncSocket.m
//
//  Created by Gold on 2016/12/29.
//  Copyright © 2016年 Gold. All rights reserved.
//

#import "JSAsyncSocket.h"
#import <sys/socket.h>
#import <netinet/in.h>
#import <netinet6/in6.h>
#import <netdb.h>
#import <arpa/inet.h>

#define SOCKET_NULL     -1
#define SOCKADDR_NULL   NULL
#define CONNECT_NULL    -1
#define SA              struct sockaddr
#define SA_4            struct sockaddr_in
#define SA_6            struct sockaddr_in6
#define AI              struct addrinfo

#define MAX_SIZE        1024

NSString *const JSAsyncSocketQueueName          = @"JSAsyncSocketQueue";
NSString *const JSAsyncSocketDelegateQueueName  = @"JSAsyncSocketDelegateQueue";
NSString *const JSAsyncSocketErrorDomain        = @"JSAsyncSocketErrorDomain";

@interface JSAsyncSocket ()
{
    BOOL preIPv4;
    BOOL enableIPv4;
    BOOL enableIPv6;
    
    BOOL isConnected;
    NSString *currentHost;
    
    int socket_4;
    int socket_6;
    
    // 主机的IPv4和IPv6地址
    SA_4 *sockaddr_4;
    SA_6 *sockaddr_6;
    
    void *IsOnAsyncSocketQueueKey;
    void *IsOnAsyncSocketQueueContext;
    
    dispatch_queue_t socketQueue;    // TCP socket 异步执行队列
    dispatch_queue_t delegateQueue; // delegate 方法执行队列
    
    dispatch_source_t readSource;
    dispatch_source_t writeSource;
    
    dispatch_source_t connectTimer;
    
    NSMutableArray *writeQueue;     // NSData数据
}

@end

@implementation JSAsyncSocket

#pragma mark -
#pragma mark INIT

- (instancetype)init {
    return [self initWithDelegateQueue:NULL];
}

- (instancetype)initWithDelegateQueue:(dispatch_queue_t)dq {
    self = [super init];
    if (self) {
        
        preIPv4 = YES;
        enableIPv4 = NO;
        enableIPv6 = NO;
        
        isConnected = NO;
        currentHost = NULL;
        
        socket_4 = SOCKET_NULL;
        socket_6 = SOCKET_NULL;
        
        sockaddr_4 = SOCKADDR_NULL;
        sockaddr_6 = SOCKADDR_NULL;
        
        socketQueue = dispatch_queue_create([JSAsyncSocketQueueName UTF8String], DISPATCH_QUEUE_SERIAL);
        IsOnAsyncSocketQueueKey = &IsOnAsyncSocketQueueContext;
        IsOnAsyncSocketQueueContext = (__bridge void *)self;
        dispatch_queue_set_specific(socketQueue, IsOnAsyncSocketQueueKey, IsOnAsyncSocketQueueContext, NULL);
        
        if (dq) {
            delegateQueue = dq;
        } else {
            delegateQueue = dispatch_queue_create([JSAsyncSocketDelegateQueueName UTF8String], DISPATCH_QUEUE_CONCURRENT);
        }
        
        writeQueue = [NSMutableArray array];
    }
    return self;
}

- (BOOL)isPreferIPv4 {
    return preIPv4;
}

- (void)setPreferIPv4:(BOOL)preferIPv4 {
    preIPv4 = preferIPv4;
}

#pragma mark -
#pragma mark DEALLOC

- (void)dealloc {
    [self disconnect];
}

#pragma mark -
#pragma mark CONNECT

// 根据主机地址和端口号，创建一个连接
// 创建时，默认选择IPv4的地址

- (void)connectToHost:(NSString *)host port:(uint16_t)port timeout:(NSTimeInterval)timeout {
    dispatch_async(socketQueue, ^{
        if (![currentHost isEqualToString:host])
            [self connectToHost:host port:port timeout:timeout error:NULL];
    });
}

- (BOOL)connectToHost:(NSString *)host
                 port:(uint16_t)port
              timeout:(NSTimeInterval)timeout
                error:(NSError **)error
{
    NSAssert(dispatch_get_specific(IsOnAsyncSocketQueueKey), @"current queue must in socket async queue");
    
    __block NSError *err = NULL;
    __block BOOL succ = NO;
    __block BOOL connected = NO;
    dispatch_block_t block = ^{ @autoreleasepool {
        dispatch_async(delegateQueue, ^{
            if (self.delegate && [self.delegate respondsToSelector:@selector(asyncSocket:willConnectedHost:)])
                [self.delegate asyncSocket:self willConnectedHost:host];
        });

        SA *addr = [self getSockaddrForHost:host port:port error:&err];
        if (err || (addr == SOCKADDR_NULL)) {
            dispatch_async(delegateQueue, ^{
                if (self.delegate && [self.delegate respondsToSelector:@selector(asyncSocket:connectFaildWithError:)])
                    [self.delegate asyncSocket:self connectFaildWithError:err];
            });
            return;
        }
        
        if (timeout > 0.0)
            [self configConnectTimeoutTimer:timeout];
        
        int sockfd;
        socklen_t len;
        // 优先IPv4
        // 创建一个地址可用的连接
        
        
        if (enableIPv4 && preIPv4) {
            socket_4 = [self createSocket:AF_INET error:&err];
            len = sizeof(SA_4);
            connected = [self socket:socket_4 connectAddr:(SA *)sockaddr_4 addrlen:len error:&err];
            sockfd = socket_4;
        } else {
            socket_6 = [self createSocket:AF_INET6 error:&err];
            len = sizeof(SA_6);
            connected = [self socket:socket_6 connectAddr:(SA *)sockaddr_6 addrlen:len error:&err];
            sockfd = socket_6;
        }
        
        [self closeConnectTimeoutConfig];
        
        if (err) {
            dispatch_async(delegateQueue, ^{
                if ([self.delegate respondsToSelector:@selector(asyncSocket:connectFaildWithError:)])
                    [self.delegate asyncSocket:self connectFaildWithError:err];
            });
            return;
        }
        
        dispatch_async(delegateQueue, ^{
            if (connected && self.delegate) {
                if ([self.delegate respondsToSelector:@selector(asyncSocket:didConnected:)])
                    [self.delegate asyncSocket:self didConnected:[self getPeerAddressForSocket:sockfd error:NULL]];
            }
        });
    }};
    
    if (dispatch_get_specific(IsOnAsyncSocketQueueKey))
        block();
    else
        dispatch_sync(socketQueue, block);
    isConnected = connected;
    if (isConnected) currentHost = [host copy];
    
    if (error)
        *error = err;
    return succ;
}

// 创建一个socket套接字
- (int)createSocket:(int)domain error:(NSError **)error {
    
    NSAssert(dispatch_get_specific(IsOnAsyncSocketQueueKey), @"current queue must in socket async queue");
    
    int sockfd = socket(domain, SOCK_STREAM, 0);
    if (sockfd == SOCKET_NULL) {
        if (error)
            *error = [JSAsyncSocket errnoError];
        return SOCKET_NULL;
    }
    
    if (error)
        *error = NULL;
    
    [self configDispatchSourceReadForSocket:sockfd];
    [self configDispatchSourceWriteForSocket:sockfd];
    
    return sockfd;
}

// 连接一个socket地址
- (BOOL)socket:(int)sockfd connectAddr:(SA *)addr addrlen:(socklen_t)len error:(NSError **)error {
    
    NSAssert(dispatch_get_specific(IsOnAsyncSocketQueueKey), @"current queue must in socket async queue");
    
    if (sockfd == SOCKET_NULL) {
        if (error)
            *error = [JSAsyncSocket socketNullError];
        return NO;
    }
    
    if (connect(sockfd, addr, len) == CONNECT_NULL) {
        if (error)
            *error = [JSAsyncSocket errnoError];
        return NO;
    }
    
    *error = NULL;
    return YES;
}

// 判断socket是否连接
- (BOOL)isConnected {
    return isConnected;
}

// 断开socket连接
- (void)disconnect {
    
    dispatch_block_t block = ^{ @autoreleasepool {
        int succ = 0;
        if (socket_4 != SOCKET_NULL)
            succ = close(socket_4);
        if (socket_6 != SOCKET_NULL)
            succ = close(socket_6);
        socket_4 = SOCKET_NULL;
        socket_6 = SOCKET_NULL;
        
        isConnected = NO;
        
        if (sockaddr_4)
            free(sockaddr_4);
        if (sockaddr_6)
            free(sockaddr_6);
        sockaddr_4 = SOCKADDR_NULL;
        sockaddr_6 = SOCKADDR_NULL;
        
        currentHost = NULL;
        
        if (readSource) {
            dispatch_source_cancel(readSource);
            readSource = NULL;
        }
        
        if (writeSource) {
            dispatch_resume(writeSource);
            dispatch_source_cancel(writeSource);
            writeSource = NULL;
        }
        
        [writeQueue removeAllObjects];
        
        dispatch_async(delegateQueue, ^{
            if (self.delegate && [self.delegate respondsToSelector:@selector(asyncSocketDidClose:)])
                [self.delegate asyncSocketDidClose:self];
        });
    }};
    
    
    dispatch_async(socketQueue, block);
}

#pragma mark -
#pragma mark CONFIGURATION

// 添加读事件监听
- (void)configDispatchSourceReadForSocket:(int)sockfd {
    
    NSAssert(dispatch_get_specific(IsOnAsyncSocketQueueKey), @"current queue must in socket async queue");
    
    readSource = dispatch_source_create(DISPATCH_SOURCE_TYPE_READ, sockfd, 0, socketQueue);
    __weak typeof(self) weakSelf = self;
    dispatch_source_set_event_handler(readSource, ^{
        
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf) return;
        unsigned long estimated_bytes = dispatch_source_get_data(readSource);
        if (estimated_bytes > 0) {
            NSData *readData;
            NSError *error;
            [self readDataFromSocket:&readData error:&error];
            if (error) {
                NSLog(@"error: %@", error.localizedDescription);
            } else {
                NSLog(@"read: %@", [[NSString alloc] initWithData:readData encoding:NSUTF8StringEncoding]);
                dispatch_async(delegateQueue, ^{
                    if (strongSelf.delegate && [strongSelf.delegate respondsToSelector:@selector(asyncSocket:didReceivedData:bytes:)])
                        [strongSelf.delegate asyncSocket:strongSelf didReceivedData:readData bytes:readData.length];
                });
            }
        } else {
            [strongSelf disconnect];
        }
    });
    dispatch_source_set_cancel_handler(readSource, ^{
        close(sockfd);
    });
    dispatch_resume(readSource);
}

// 添加写事件监听
- (void)configDispatchSourceWriteForSocket:(int)sockfd {
    
    NSAssert(dispatch_get_specific(IsOnAsyncSocketQueueKey), @"current queue must in socket async queue");
    
    writeSource = dispatch_source_create(DISPATCH_SOURCE_TYPE_WRITE, sockfd, 0, socketQueue);
    __weak typeof(self) weakSelf = self;
    dispatch_source_set_event_handler(writeSource, ^{
        
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf) return;
        unsigned long buffer = dispatch_source_get_data(writeSource);
        if (buffer > 0) {
            [strongSelf writeData];
        }
    });
    dispatch_source_set_cancel_handler(writeSource, ^{
        close(sockfd);
    });
//    dispatch_resume(writeSource);
}

// 配置连接超时
- (void)configConnectTimeoutTimer:(NSTimeInterval)timeout {
    
    NSAssert(dispatch_get_specific(IsOnAsyncSocketQueueKey), @"current queue must in socket async queue");
    
    connectTimer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, socketQueue);
    __weak typeof(self) weakSelf = self;
    dispatch_source_set_event_handler(connectTimer, ^{
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf) return;
        if (!isConnected) {
            if (strongSelf.delegate && [strongSelf.delegate respondsToSelector:@selector(asyncSocket:connectFaildWithError:)])
                [strongSelf.delegate asyncSocket:strongSelf connectFaildWithError:[JSAsyncSocket connectTimeoutError]];
            [strongSelf disconnect];
        }
        dispatch_source_cancel(connectTimer);
    });
    dispatch_source_set_cancel_handler(connectTimer, ^{
        connectTimer = NULL;
    });
    dispatch_time_t time_out = dispatch_time(DISPATCH_TIME_NOW, timeout * NSEC_PER_SEC);
    dispatch_source_set_timer(connectTimer, time_out, DISPATCH_TIME_FOREVER, 0);
    dispatch_resume(connectTimer);
}

// 在超时限定时间内，连接成功或连接关闭都关闭配置
- (void)closeConnectTimeoutConfig {
    
    NSAssert(dispatch_get_specific(IsOnAsyncSocketQueueKey), @"current queue must in socket async queue");
    
    if (connectTimer)
        dispatch_source_cancel(connectTimer);
}

#pragma mark -
#pragma mark READ

// 从socket读出数据
- (ssize_t)readDataFromSocket:(NSData **)readData error:(NSError **)error {
    
    NSAssert(dispatch_get_specific(IsOnAsyncSocketQueueKey), @"current queue must in socket async queue");
    
    static char readline[MAX_SIZE];
    int sockfd = ((socket_4 != SOCKET_NULL) && preIPv4) ? socket_4 : socket_6;
    ssize_t size = read(sockfd, readline, MAX_SIZE);
    
    if (error) {
        *error = (size == -1) ? [JSAsyncSocket errnoError] : NULL;
    }
    if (readData) {
        *readData = [NSData dataWithBytes:readline length:size];
    }
    return size;
}

#pragma mark -
#pragma mark WRITE

- (void)writeDataToSocket:(NSData *)writeData {
    dispatch_async(socketQueue, ^{
        [writeQueue addObject:writeData];
        dispatch_resume(writeSource);
//        [self writeData];
    });
}

- (void)writeData {
    
    NSAssert(dispatch_get_specific(IsOnAsyncSocketQueueKey), @"current queue must in socket async queue");
    
    NSError *error = NULL;
    while (writeQueue.count > 0) { @autoreleasepool {
        NSData *data = writeQueue.firstObject;
        ssize_t size = [self writeDataToSocket:data error:&error];
        if (size < 0 || error) {
            NSLog(@"write data to socket error: %@", error.localizedDescription);
        }
        [writeQueue removeObjectAtIndex:0];
    }}
    
    dispatch_suspend(writeSource);
}

// 向socket写入数据
- (ssize_t)writeDataToSocket:(NSData *)writeData error:(NSError *__autoreleasing *)error {
    
    NSAssert(dispatch_get_specific(IsOnAsyncSocketQueueKey), @"current queue must in socket async queue");
    
    if (writeData.length <= 0) {
        if (error)
            *error = [JSAsyncSocket noDataWriteError];
        return 0;
    }
    
    int sockfd = ((socket_4 != SOCKET_NULL) && preIPv4) ? socket_4 : socket_6;
    ssize_t size = write(sockfd, writeData.bytes, writeData.length);
    if (size == writeData.length) {
        if (error)
            *error = NULL;
        dispatch_async(delegateQueue, ^{
            if (self.delegate && [self.delegate respondsToSelector:@selector(asyncSocket:didSendData:bytes:)])
                [self.delegate asyncSocket:self didSendData:writeData bytes:size];
        });
    } else {
        if (error)
            *error = [JSAsyncSocket errnoError];
    }
    return size;
}

#pragma mark -
#pragma mark UTIL

// 根据主机和端口号，设置IPv4和IPv6的地址
- (SA *)getSockaddrForHost:(NSString *)host port:(uint16_t)port error:(NSError **)error {
    
    NSAssert(dispatch_get_specific(IsOnAsyncSocketQueueKey), @"current queue must in socket async queue");
    
    if (host.length <= 0) {
        if (error)
            *error = [JSAsyncSocket invalidHostError];
        return SOCKADDR_NULL;
    }
    
    AI hints, *res, *ori;
    hints.ai_family = AF_UNSPEC;
    hints.ai_socktype = SOCK_STREAM;
    hints.ai_protocol = IPPROTO_TCP;
    
    NSString *portServ = [NSString stringWithFormat:@"%u", port];
    int err = getaddrinfo([host UTF8String], [portServ UTF8String], &hints, &res);
    if (err != 0) {
        if (error)
            *error = [JSAsyncSocket gai_strerror:err];
        return SOCKADDR_NULL;
    }
    
    ori = res;
    SA *addr = SOCKADDR_NULL;
    
    while (res) {
        if (res->ai_family == AF_INET) {
            enableIPv4 = YES;
            if (sockaddr_4 == SOCKADDR_NULL) {
                sockaddr_4 = malloc(sizeof(SA_4));
                bzero(sockaddr_4, sizeof(SA_4));
            }
            sockaddr_4 = memcpy(sockaddr_4, res->ai_addr, MIN(res->ai_addrlen, sizeof(SA_4)));
            sockaddr_4->sin_port = htons(port);
        }
        else if (res->ai_family == AF_INET6) {
            enableIPv6 = YES;
            if (sockaddr_6 == SOCKADDR_NULL) {
                sockaddr_6 = malloc(sizeof(SA_6));
                bzero(sockaddr_6, sizeof(SA_6));
            }
            sockaddr_6 = memcpy(sockaddr_6, res->ai_addr, MIN(res->ai_addrlen, sizeof(SA_6)));
            sockaddr_6->sin6_port = htons(port);
        }
        else {  // 既不支持IPv4也不支持IPv6
            addr = res->ai_addr;
        }
        res = res->ai_next;
    }
    
    if (ori == res) {   // ori and res are NULL
        if (error)
            *error = [JSAsyncSocket invalidHostError];
        return SOCKADDR_NULL;
    } else {
        if (addr && (addr->sa_family != AF_INET) && (addr->sa_family != AF_INET6)) {
            if (error)
                *error = [JSAsyncSocket invalidHostError];
            return SOCKADDR_NULL;
        } else {
            freeaddrinfo(ori);
            if (error)
                *error = NULL;
            return (preIPv4) ? (SA *)sockaddr_4 : (SA *)sockaddr_6;
        }
    }
}

// 获取socket的peer的地址
- (NSData *)getPeerAddressForSocket:(int)sockfd error:(NSError **)error {
    
    __block NSData *addrData = NULL;
    __block NSError *err = NULL;
    
    dispatch_block_t block = ^{ @autoreleasepool {
        SA *addr = malloc(sizeof(SA));
        socklen_t len = sizeof(SA);
        bzero(addr, sizeof(SA));
        int flag = getpeername(sockfd, addr, &len);
        if (flag != 0) {
            err = [JSAsyncSocket errnoError];
        }
        addrData = [NSData dataWithBytes:addr length:len];
        free(addr);
    }};
    if (dispatch_get_specific(IsOnAsyncSocketQueueKey))
        block();
    else
        dispatch_sync(socketQueue, block);
    
    if (error) *error = err;
    return addrData;
}

#pragma mark -
#pragma mark ERROR

+ (NSError *)invalidHostError {
    NSDictionary *userInfo = @{NSLocalizedDescriptionKey: @"无效的主机地址"};
    return [NSError errorWithDomain:JSAsyncSocketErrorDomain code:JSAsyncSocketErrorInvalidHost userInfo:userInfo];
}

+ (NSError *)gai_strerror:(int)error {
    const char *str = gai_strerror(error);
    NSDictionary *userInfo = @{NSLocalizedDescriptionKey: [NSString stringWithUTF8String:str]};
    return [NSError errorWithDomain:JSAsyncSocketErrorDomain code:error userInfo:userInfo];
}

+ (NSError *)errnoError {
    NSDictionary *userInfo = @{NSLocalizedDescriptionKey: [NSString stringWithUTF8String:strerror(errno)]};
    return [NSError errorWithDomain:JSAsyncSocketErrorDomain code:errno userInfo:userInfo];
}

+ (NSError *)socketNullError {
    NSDictionary *userInfo = @{NSLocalizedDescriptionKey: @"无效的socket"};
    return [NSError errorWithDomain:JSAsyncSocketErrorDomain code:JSAsyncSocketErrorSocketNull userInfo:userInfo];
}

+ (NSError *)noDataWriteError {
    NSDictionary *userInfo = @{NSLocalizedDescriptionKey: @"没有数据可以发送"};
    return [NSError errorWithDomain:JSAsyncSocketErrorDomain code:JSAsyncSocketErrorNoDataWrite userInfo:userInfo];
}

+ (NSError *)connectTimeoutError {
    NSDictionary *userInfo = @{NSLocalizedDescriptionKey: @"连接主机超时"};
    return [NSError errorWithDomain:JSAsyncSocketErrorDomain code:JSAsyncSocketErrorConnectTimeout userInfo:userInfo];
}

@end

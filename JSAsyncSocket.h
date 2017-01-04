//
//  JSAsyncSocket.h
//
//  Created by Gold on 2016/12/29.
//  Copyright © 2016年 Gold. All rights reserved.
//

#import <Foundation/Foundation.h>

typedef enum : NSUInteger {
    JSAsyncSocketErrorInvalidHost = 1001,   // 无效的主机地址
    JSAsyncSocketErrorSocketNull,           // 无效的socket
    JSAsyncSocketErrorNoDataWrite,          // 没有数据可以发送
    JSAsyncSocketErrorConnectTimeout,       // 连接主机超时
} JSAsyncSocketErrorCode;

@class JSAsyncSocket;

@protocol JSAsyncSocketDelegate <NSObject>
@optional
- (void)asyncSocket:(JSAsyncSocket *)sock willConnectedHost:(NSString *)host;
- (void)asyncSocket:(JSAsyncSocket *)sock didConnected:(NSData *)addr;
- (void)asyncSocket:(JSAsyncSocket *)sock connectFaildWithError:(NSError *)error;
- (void)asyncSocket:(JSAsyncSocket *)sock didReceivedData:(NSData *)data bytes:(ssize_t)bytes;
- (void)asyncSocket:(JSAsyncSocket *)sock didSendData:(NSData *)data bytes:(ssize_t)bytes;
- (void)asyncSocketDidClose:(JSAsyncSocket *)sock;
@end

@interface JSAsyncSocket : NSObject

/**
 *  JSAsyncSocket是一个基于iOS平台的、构建于TCP协议的socket组件
 *  组件创建了一个socketQueue，所有关于连接、读写都是异步执行，
 *  当有数据需要发送，需要调用writeDataToSocket方法
 *  当有对端数据发送过来时，asyncSocket:didReceivedData:bytes会被调用
 *
 *  支持IPv4和IPv6，运行环境为ARC
 */

@property (nonatomic, assign, getter=isPreferIPv4) BOOL preferIPv4; // 是否优先IPv4, 默认为YES
@property (nonatomic, weak) id<JSAsyncSocketDelegate> delegate;

// 初始化，如果delegateQueue为NULL，则创建一个queue
- (instancetype)initWithDelegateQueue:(dispatch_queue_t)delegateQueue;

// 根据主机地址和端口号进行socket连接，如果timeout大于0.0则添加连接超时
- (void)connectToHost:(NSString *)host port:(uint16_t)port timeout:(NSTimeInterval)timeout;

// 判断socket是否连接
- (BOOL)isConnected;

// 断开连接
- (void)disconnect;

// 向socket写入数据
- (void)writeDataToSocket:(NSData *)writeData;

@end

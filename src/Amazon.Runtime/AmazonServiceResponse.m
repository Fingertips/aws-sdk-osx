/*
 * Copyright 2010-2013 Amazon.com, Inc. or its affiliates. All Rights Reserved.
 *
 * Licensed under the Apache License, Version 2.0 (the "License").
 * You may not use this file except in compliance with the License.
 * A copy of the License is located at
 *
 *  http://aws.amazon.com/apache2.0
 *
 * or in the "license" file accompanying this file. This file is distributed
 * on an "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either
 * express or implied. See the License for the specific language governing
 * permissions and limitations under the License.
 */


#import "AmazonServiceResponse.h"
#import "AmazonServiceResponseUnmarshaller.h"
#import "AmazonLogger.h"


@implementation AmazonServiceResponse

@synthesize httpStatusCode;
@synthesize isFinishedLoading;
@synthesize request;
@synthesize requestId;
@synthesize didTimeout;
@synthesize unmarshallerDelegate;
@synthesize processingTime;
@synthesize error;
@synthesize exception;

-(id)init
{
    self = [super init];
    if (self != nil) {
        isFinishedLoading = NO;
        didTimeout        = NO;
        exception         = nil;
        error = nil;
    }

    return self;
}

-(NSData *)body
{
    return [NSData dataWithData:body];
}

// Override this to perform processing on the body.
-(void)processBody
{
    // Subclasses can use this to build object data from the response, for example
    // parsing XML content.
}

-(void)postProcess
{
}

-(void)timeout
{
    if (!isFinishedLoading && !exception) {
        
        didTimeout = YES;
        [self.request.urlConnection cancel];
        self.request.responseTimer = nil;
        
        exception = [[AmazonServiceException exceptionWithMessage:@"Request timed out."] retain];
        // Configure an error like NSURLConnection would so a retry will be performed by:
        // -[AmazonAbstractWebServiceClient shouldRetry:exception:]
        [(AmazonServiceException *)exception setError:[NSError errorWithDomain:NSURLErrorDomain code:kCFURLErrorTimedOut userInfo:nil]];
        
        BOOL throwsExceptions = [AmazonErrorHandler throwsExceptions];
        
        if (throwsExceptions == YES
            && [(NSObject *)request.delegate respondsToSelector:@selector(request:didFailWithServiceException:)]) {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
            [request.delegate request:request didFailWithServiceException:exception];
#pragma clang diagnostic pop
        }
        else if (throwsExceptions == NO
                 && [(NSObject *)request.delegate respondsToSelector:@selector(request:didFailWithError:)]) {
            
            self.error = [AmazonErrorHandler errorFromException:exception];
            [request.delegate request:request didFailWithError:self.error];
        }
    }
}

#pragma mark - NSURLProtocolClient delegate methods

-(void)connection:(NSURLConnection *)connection didReceiveResponse:(NSURLResponse *)response
{
    NSHTTPURLResponse *httpResponse = (NSHTTPURLResponse *)response;

    AMZLogDebug(@"Response Headers:");
    for (NSString *header in [[httpResponse allHeaderFields] allKeys]) {
        AMZLogDebug(@"%@ = [%@]", header, [[httpResponse allHeaderFields] valueForKey:header]);
    }

    self.httpStatusCode = [httpResponse statusCode];

    [body setLength:0];

    if ([(NSObject *)self.request.delegate respondsToSelector:@selector(request:didReceiveResponse:)]) {
        [self.request.delegate request:self.request didReceiveResponse:response];
    }
}

-(void)connection:(NSURLConnection *)connection didReceiveData:(NSData *)data
{
    if (nil == body) {
        body = [[NSMutableData data] retain];
    }

    [body appendData:data];

    if ([(NSObject *)self.request.delegate respondsToSelector:@selector(request:didReceiveData:)]) {
        [self.request.delegate request:self.request didReceiveData:data];
    }
}

-(void)connectionDidFinishLoading:(NSURLConnection *)connection
{
    [self.request.responseTimer invalidate];
    
    NSDate *startDate = [NSDate date];

    isFinishedLoading = YES;

    NSString *tmpStr = [[NSString alloc] initWithData:body encoding:NSUTF8StringEncoding];

    AMZLogDebug(@"Response Body:\n%@", tmpStr);
    [tmpStr release];
    NSXMLParser                       *parser         = [[NSXMLParser alloc] initWithData:body];
    AmazonServiceResponseUnmarshaller *parserDelegate = [[unmarshallerDelegate alloc] init];
    [parser setDelegate:parserDelegate];
    [parser parse];

    AmazonServiceResponse *response = [[parserDelegate response] retain];

    [parser release];
    [parserDelegate release];

    if(response.error)
    {
        NSError *errorFound = [[response.error copy] autorelease];
        [response release];
        
        if ([(NSObject *)request.delegate respondsToSelector:@selector(request:didFailWithError:)]) {
            [request.delegate request:request didFailWithError:errorFound];
        }
    }
    else if (response.exception) {
        NSException *exceptionFound = [[response.exception copy] autorelease];
        [response release];
        
        BOOL throwsExceptions = [AmazonErrorHandler throwsExceptions];
        
        if(throwsExceptions == YES
           && [(NSObject *)request.delegate respondsToSelector:@selector(request:didFailWithServiceException:)]) {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
            [request.delegate request:request didFailWithServiceException:(AmazonServiceException *)exceptionFound];
#pragma clang diagnostic pop
        }
        else if(throwsExceptions == NO
                && [(NSObject *)request.delegate respondsToSelector:@selector(request:didFailWithError:)]) {
            [request.delegate request:request 
                     didFailWithError:[AmazonErrorHandler errorFromException:exceptionFound]];
        }
    }
    else {
        [response postProcess];
        processingTime          = fabs([startDate timeIntervalSinceNow]);
        response.processingTime = processingTime;
        

        
        if ([(NSObject *)request.delegate respondsToSelector:@selector(request:didCompleteWithResponse:)]) {
            [request.delegate request:request didCompleteWithResponse:response];
        }
        
        [response release];
    }
}

-(void)connection:(NSURLConnection *)connection didFailWithError:(NSError *)theError
{
    [self.request.responseTimer invalidate];

    NSDictionary *info = [theError userInfo];
    for (id key in info)
    {
        AMZLogDebug(@"UserInfo.%@ = %@", [key description], [[info valueForKey:key] description]);
    }
    exception = [[AmazonServiceException exceptionWithMessage:[theError description] andError:theError] retain];
    AMZLogDebug(@"An error occured in the request: %@", [theError description]);
    
    if ([(NSObject *)self.request.delegate respondsToSelector:@selector(request:didFailWithError:)]) {
        [self.request.delegate request:self.request didFailWithError:theError];
    }
}

-(void)connection:(NSURLConnection *)connection didSendBodyData:(NSInteger)bytesWritten totalBytesWritten:(NSInteger)totalBytesWritten totalBytesExpectedToWrite:(NSInteger)totalBytesExpectedToWrite
{
    if ([(NSObject *)self.request.delegate respondsToSelector:@selector(request:didSendData:totalBytesWritten:totalBytesExpectedToWrite:)]) {
        [self.request.delegate request:self.request
         didSendData:bytesWritten
         totalBytesWritten:totalBytesWritten
         totalBytesExpectedToWrite:totalBytesExpectedToWrite];
    }
}

// When a request gets a redirect due to the bucket being in a different region,
// The request gets re-written with a GET http method. This is to set the method back to
// the appropriate method if necessary
-(NSURLRequest *)connection:(NSURLConnection *)connection willSendRequest:(NSURLRequest *)proposedRequest redirectResponse:(NSURLResponse *)redirectResponse
{
    return proposedRequest;
}

-(NSCachedURLResponse *)connection:(NSURLConnection *)connection willCacheResponse:(NSCachedURLResponse *)cachedResponse
{
    return nil;
}

// FOR TESTING ONLY - disables SSL cert checks
//- (BOOL)connection:(NSURLConnection *)connection canAuthenticateAgainstProtectionSpace:(NSURLProtectionSpace *)protectionSpace {
//    return [protectionSpace.authenticationMethod isEqualToString:NSURLAuthenticationMethodServerTrust];
//}

//- (void)connection:(NSURLConnection *)connection didReceiveAuthenticationChallenge:(NSURLAuthenticationChallenge *)challenge {
//    [challenge.sender useCredential:[NSURLCredential credentialForTrust:challenge.protectionSpace.serverTrust] forAuthenticationChallenge:challenge];
//    
//    [challenge.sender continueWithoutCredentialForAuthenticationChallenge:challenge];
//}

#pragma mark memory management

-(void)dealloc
{
    [requestId release];
    [body release];
    [exception release];
    [request release];
    [error release];

    [super dealloc];
}

-(NSString *)description
{
    NSMutableString *buffer = [[NSMutableString alloc] initWithCapacity:256];

    [buffer appendString:@"{"];
    [buffer appendString:[[[NSString alloc] initWithFormat:@"requestId: %@", requestId] autorelease]];
    [buffer appendString:@"}"];

    return [buffer autorelease];
}

@end






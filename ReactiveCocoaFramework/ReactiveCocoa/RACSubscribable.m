//
//  RACSubscribable.m
//  ReactiveCocoa
//
//  Created by Josh Abernathy on 3/15/12.
//  Copyright (c) 2012 GitHub, Inc. All rights reserved.
//

#import "RACSubscribable.h"
#import "RACSubscribable+Private.h"
#import "RACSubject.h"
#import "RACDisposable.h"
#import "RACAsyncSubject.h"
#import "NSObject+RACExtensions.h"
#import "RACScheduler.h"
#import <libkern/OSAtomic.h>

static NSMutableSet *activeSubscribables() {
	static dispatch_once_t onceToken;
	static NSMutableSet *activeSubscribables = nil;
	dispatch_once(&onceToken, ^{
		activeSubscribables = [[NSMutableSet alloc] init];
	});
	
	return activeSubscribables;
}

@interface RACSubscribable ()
@property (assign, getter=isTearingDown) BOOL tearingDown;
@end


@implementation RACSubscribable

- (instancetype)init {
	self = [super init];
	if(self == nil) return nil;
	
	// We want to keep the subscribable around until all its subscribers are done
	@synchronized(activeSubscribables()) {
		[activeSubscribables() addObject:self];
	}
	
	self.tearingDown = NO;
	self.subscribers = [NSMutableArray array];
	
	// As soon as we're created we're already trying to be released. Such is life.
	[self invalidateGlobalRefIfNoNewSubscribersShowUp];
	
	return self;
}

- (NSString *)description {
	return [NSString stringWithFormat:@"<%@: %p> name: %@", NSStringFromClass([self class]), self, self.name];
}


#pragma mark RACSubscribable

- (RACDisposable *)subscribe:(id<RACSubscriber>)subscriber {
	NSParameterAssert(subscriber != nil);
	
	@synchronized(self.subscribers) {
		[self.subscribers addObject:subscriber];
	}
	
	__block __unsafe_unretained id weakSelf = self;
	__block __unsafe_unretained id weakSubscriber = subscriber;
	RACDisposable *defaultDisposable = [RACDisposable disposableWithBlock:^{
		RACSubscribable *strongSelf = weakSelf;
		id<RACSubscriber> strongSubscriber = weakSubscriber;
		// If the disposal is happening because the subscribable's being torn
		// down, we don't need to duplicate the invalidation.
		if(!strongSelf.tearingDown) {
			BOOL stillHasSubscribers = YES;
			@synchronized(strongSelf.subscribers) {
				[strongSelf.subscribers removeObject:strongSubscriber];
				stillHasSubscribers = strongSelf.subscribers.count > 0;
			}
			
			if(!stillHasSubscribers) {
				[strongSelf invalidateGlobalRefIfNoNewSubscribersShowUp];
			}
		}
	}];

	RACDisposable *disposable = defaultDisposable;
	if(self.didSubscribe != NULL) {
		RACDisposable *innerDisposable = self.didSubscribe(subscriber);
		disposable = [RACDisposable disposableWithBlock:^{
			[innerDisposable dispose];
			[defaultDisposable dispose];
		}];
	}
	
	[subscriber didSubscribeWithDisposable:disposable];
	
	return disposable;
}


#pragma mark API

@synthesize didSubscribe;
@synthesize subscribers;
@synthesize tearingDown;
@synthesize name;

+ (instancetype)createSubscribable:(RACDisposable * (^)(id<RACSubscriber> subscriber))didSubscribe {
	RACSubscribable *subscribable = [[self alloc] init];
	subscribable.didSubscribe = didSubscribe;
	return subscribable;
}

+ (instancetype)generatorWithStart:(id)start next:(id (^)(id x))block {
	return [self generatorWithScheduler:nil start:start next:block];
}

+ (instancetype)generatorWithScheduler:(RACScheduler *)scheduler start:(id)start next:(id (^)(id x))block {
	NSParameterAssert(block != NULL);

	if (scheduler == nil) scheduler = [RACScheduler backgroundScheduler];

	return [self createSubscribable:^(id<RACSubscriber> subscriber) {
		__block volatile uint32_t dispose = 0;
		[scheduler schedule:^{
			id next = start;
			while (next != nil && dispose == 0) {
				[subscriber sendNext:next];
				next = block(next);
			}
			
			// Only send completed if we weren't manually disposed of.
			// Otherwise we could send a message to subscribers after their
			// subscription's been disposed which would violate the contract of
			// subscription + disposal.
			if (dispose == 0) {
				[subscriber sendCompleted];
			}
		}];

		return [RACDisposable disposableWithBlock:^{
			OSAtomicOr32Barrier(1, &dispose);
		}];
	}];
}

+ (instancetype)return:(id)value {
	return [self createSubscribable:^RACDisposable *(id<RACSubscriber> subscriber) {
		[subscriber sendNext:value];
		[subscriber sendCompleted];
		return nil;
	}];
}

+ (instancetype)error:(NSError *)error {
	return [self createSubscribable:^RACDisposable *(id<RACSubscriber> subscriber) {
		[subscriber sendError:error];
		return nil;
	}];
}

+ (instancetype)empty {
	return [self createSubscribable:^RACDisposable *(id<RACSubscriber> subscriber) {
		[subscriber sendCompleted];
		return nil;
	}];
}

+ (instancetype)never {
	return [self createSubscribable:^RACDisposable *(id<RACSubscriber> subscriber) {
		return nil;
	}];
}

+ (RACSubscribable *)start:(id (^)(BOOL *success, NSError **error))block {
	return [self startWithScheduler:[RACScheduler backgroundScheduler] block:block];
}

+ (RACSubscribable *)startWithScheduler:(RACScheduler *)scheduler block:(id (^)(BOOL *success, NSError **error))block {
	return [self startWithScheduler:scheduler subjectBlock:^(RACSubject *subject) {
		BOOL success = YES;
		NSError *error = nil;
		id returned = block(&success, &error);
		
		if(!success) {
			[subject sendError:error];
		} else {
			[subject sendNext:returned];
			[subject sendCompleted];
		}
	}];
}

+ (RACSubscribable *)startWithScheduler:(RACScheduler *)scheduler subjectBlock:(void (^)(RACSubject *subject))block {
	NSParameterAssert(block != NULL);

	RACAsyncSubject *subject = [RACAsyncSubject subject];
	[scheduler schedule:^{
		block(subject);
	}];
	
	return subject;
}

- (void)invalidateGlobalRefIfNoNewSubscribersShowUp {
	// If no one subscribed in the runloop's pass, then we're free to go. It's
	// up to the caller to keep us alive if they still want us.
	[self rac_performBlock:^{
		BOOL hasSubscribers = YES;
		@synchronized(self.subscribers) {
			hasSubscribers = self.subscribers.count > 0;
		}
		
		if(!hasSubscribers) {
			[self invalidateGlobalRef];
		}
	} afterDelay:0];
}

- (void)invalidateGlobalRef {
	@synchronized(activeSubscribables()) {
		[activeSubscribables() removeObject:self];
	}
}

- (void)performBlockOnEachSubscriber:(void (^)(id<RACSubscriber> subscriber))block {
	NSParameterAssert(block != NULL);

	NSArray *currentSubscribers = nil;
	@synchronized(self.subscribers) {
		currentSubscribers = [self.subscribers copy];
	}
	
	for(id<RACSubscriber> subscriber in currentSubscribers) {
		block(subscriber);
	}
}

- (void)tearDown {
	self.tearingDown = YES;
	
	@synchronized(self.subscribers) {
		[self.subscribers removeAllObjects];
	}
	
	[self invalidateGlobalRef];
}

@end

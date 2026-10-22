#ifndef ObjCGuard_h
#define ObjCGuard_h

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Runs `block`, converting any Objective-C exception into a returned reason.
///
/// AVFoundation raises `NSException` for ordinary misuse — a notable one being
/// `-[AVAudioPlayerNode play]` throwing "player started when in a disconnected
/// state" when the engine's graph failed to form. Swift cannot catch an
/// NSException, so such a throw terminates the process with no crash report and
/// no chance to show the user anything. No public AVAudioEngine property
/// reliably predicts that state, so the call has to be attempted defensively.
///
/// Returns nil on success, or the exception's reason (never empty) on failure.
NSString *_Nullable NLGuardRun(void (NS_NOESCAPE ^block)(void));

NS_ASSUME_NONNULL_END

#endif /* ObjCGuard_h */

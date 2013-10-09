//
//  main.m
//  shipit
//
//  Created by Alan Rogers on 29/07/2013.
//  Copyright (c) 2013 GitHub. All rights reserved.
//

#import <Foundation/Foundation.h>
#import <ReactiveCocoa/EXTScope.h>
#import <ReactiveCocoa/ReactiveCocoa.h>
#import "NSError+SQRLVerbosityExtensions.h"
#import "RACSignal+SQRLTransactionExtensions.h"
#import "SQRLCodeSignature.h"
#import "SQRLDirectoryManager.h"
#import "SQRLInstaller.h"
#import "SQRLShipItState.h"
#import "SQRLTerminationListener.h"

// The maximum number of times ShipIt should run the same installation state, in
// an attempt to update.
//
// If ShipIt is launched in the same state more than this number of times,
// updating will abort.
static const NSUInteger SQRLShipItMaximumInstallationAttempts = 3;

// The domain for errors generated here.
static NSString * const SQRLShipItErrorDomain = @"SQRLShipItErrorDomain";

// Waits for all instances of the target application (as described in the
// `state`) to exit, then sends completed.
static RACSignal *waitForTerminationIfNecessary(SQRLShipItState *state) {
	return [[RACSignal
		defer:^{
			if (state.bundleIdentifier == nil) return [RACSignal empty];

			SQRLTerminationListener *listener = [[SQRLTerminationListener alloc] initWithURL:state.targetBundleURL bundleIdentifier:state.bundleIdentifier];
			return [listener waitForTermination];
		}]
		setNameWithFormat:@"waitForTerminationIfNecessary"];
}

int main(int argc, const char * argv[]) {
	@autoreleasepool {
		atexit_b(^{
			NSLog(@"ShipIt quitting");
		});

		if (argc < 2) {
			NSLog(@"Missing launchd job label for ShipIt");
			return EXIT_FAILURE;
		}

		const char *jobLabel = argv[1];
		SQRLDirectoryManager *directoryManager = [[SQRLDirectoryManager alloc] initWithApplicationIdentifier:@(jobLabel)];

		[[[[SQRLShipItState
			readUsingDirectoryManager:directoryManager]
			catch:^(NSError *error) {
				NSLog(@"Error reading saved installer state: %@", error);

				// Exit successfully so launchd doesn't restart us again.
				return [RACSignal empty];
			}]
			flattenMap:^(SQRLShipItState *state) {
				BOOL freshInstall = (state.installerState == SQRLInstallerStateNothingToDo);
				SQRLInstaller *installer = [[SQRLInstaller alloc] initWithDirectoryManager:directoryManager];

				if (++state.installationStateAttempt > SQRLShipItMaximumInstallationAttempts) {
					return [[[waitForTerminationIfNecessary(state)
						then:^{
							return [installer.abortInstallationCommand execute:state];
						}]
						initially:^{
							NSLog(@"Too many attempts to install from state %i, aborting update", (int)state.installerState);
						}]
						catch:^(NSError *error) {
							NSLog(@"Error aborting installation: %@", error);

							// Exit successfully so launchd doesn't restart us again.
							return [RACSignal empty];
						}];
				} else {
					state.installerState = SQRLInstallerStateClearingQuarantine;

					// Save our changes to `installerState` and
					// `installationStateAttempt`.
					return [[[[state
						writeUsingDirectoryManager:directoryManager]
						then:^{
							return waitForTerminationIfNecessary(state);
						}]
						then:^{
							return [[installer.installUpdateCommand
								execute:state]
								initially:^{
									if (freshInstall) {
										NSLog(@"Beginning installation");
									} else {
										NSLog(@"Resuming installation from state %i", (int)state.installerState);
									}
								}];
						}]
						doCompleted:^{
							NSLog(@"Installation completed successfully");
						}];
				}
			}]
			subscribeError:^(NSError *error) {
				NSLog(@"Installation error: %@", error);
				exit(EXIT_FAILURE);
			} completed:^{
				exit(EXIT_SUCCESS);
			}];

		dispatch_main();
	}

	return EXIT_SUCCESS;
}


//
//  PAPWelcomeViewController.m
//  Anypic
//
//  Created by Héctor Ramos on 5/10/12.
//  Copyright (c) 2013 Parse. All rights reserved.
//

#import "PAPWelcomeViewController.h"
#import "AppDelegate.h"
#import "PAPUtility.h"
#import "PAPCache.h"

#import <FBSDKCoreKit/FBSDKCoreKit.h>

@interface PAPWelcomeViewController() {
    BOOL _presentedLoginViewController;
    int _facebookResponseCount;
    int _expectedFacebookResponseCount;
    NSMutableData *_profilePicData;
}

@end

@implementation PAPWelcomeViewController

#pragma mark - UIViewController
- (void)loadView {
    UIImageView *backgroundImageView = [[UIImageView alloc] initWithFrame:[[UIScreen mainScreen] bounds]];
    [backgroundImageView setImage:[UIImage imageNamed:@"Default.png"]];
    self.view = backgroundImageView;
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    
    if (![PFUser currentUser]) {
        [self presentLoginViewController:NO];
        return;
    }

    // Present Anypic UI
    [(AppDelegate *)[[UIApplication sharedApplication] delegate] presentTabBarController];
    
    // Refresh current user with server side data -- checks if user is still valid and so on
    _facebookResponseCount = 0;
    [[PFUser currentUser] fetchInBackgroundWithBlock:^(PFObject * _Nullable object, NSError * _Nullable error) {
        [self refreshCurrentUserCallbackWithResult:object error:error];
    }];
}


#pragma mark - PAPWelcomeViewController

- (void)presentLoginViewController:(BOOL)animated {
    if (_presentedLoginViewController) {
        return;
    }
    
    _presentedLoginViewController = YES;
    PAPLogInViewController *loginViewController = [[PAPLogInViewController alloc] init];
    loginViewController.delegate = self;
    [self presentViewController:loginViewController animated:animated completion:nil];
}


#pragma mark - PAPLoginViewControllerDelegate

- (void)logInViewControllerDidLogUserIn:(PAPLogInViewController *)logInViewController {
    if (_presentedLoginViewController) {
        _presentedLoginViewController = NO;
        [self dismissViewControllerAnimated:YES completion:nil];
    }
}


#pragma mark - ()

- (void)processedFacebookResponse {
    // Once we handled all necessary facebook batch responses, save everything necessary and continue
    @synchronized (self) {
        _facebookResponseCount++;
        if (_facebookResponseCount != _expectedFacebookResponseCount) {
            return;
        }
    }
    _facebookResponseCount = 0;
    NSLog(@"done processing all Facebook requests");
    
    [[PFUser currentUser] saveInBackgroundWithBlock:^(BOOL succeeded, NSError *error) {
        if (!succeeded) {
            NSLog(@"Failed save in background of user, %@", error);
        } else {
            NSLog(@"saved current parse user");
        }
    }];
}


- (void)refreshCurrentUserCallbackWithResult:(PFObject *)refreshedObject error:(NSError *)error {
    // This fetches the most recent data from FB, and syncs up all data with the server including profile pic and friends list from FB.
    
    // A kPFErrorObjectNotFound error on currentUser refresh signals a deleted user
    if (error && error.code == kPFErrorObjectNotFound) {
        NSLog(@"User does not exist.");
        [(AppDelegate *)[[UIApplication sharedApplication] delegate] logOut];
        return;
    }

    if (![FBSDKAccessToken currentAccessToken]) {
        NSLog(@"FB Session does not exist, logout");
        [(AppDelegate *)[[UIApplication sharedApplication] delegate] logOut];
        return;
    }
    
    if (![FBSDKAccessToken currentAccessToken].userID) {
        NSLog(@"userID on FB Session does not exist, logout");
        [(AppDelegate *)[[UIApplication sharedApplication] delegate] logOut];
        return;
    }
    
    PFUser *currentParseUser = [PFUser currentUser];
    if (!currentParseUser) {
        NSLog(@"Current Parse user does not exist, logout");
        [(AppDelegate *)[[UIApplication sharedApplication] delegate] logOut];
        return;
    }
    
    NSString *facebookId = [currentParseUser objectForKey:kPAPUserFacebookIDKey];
    if (!facebookId || ![facebookId length]) {
        // set the parse user's FBID
        [currentParseUser setObject:[FBSDKAccessToken currentAccessToken].userID forKey:kPAPUserFacebookIDKey];
    }
    
    if (![PAPUtility userHasValidFacebookData:currentParseUser]) {
        NSLog(@"User does not have valid facebook ID. PFUser's FBID: %@, FBSessions FBID: %@. logout", [currentParseUser objectForKey:kPAPUserFacebookIDKey], [FBSDKAccessToken currentAccessToken].userID);
        [(AppDelegate *)[[UIApplication sharedApplication] delegate] logOut];
        return;
    }
    
    // Finished checking for invalid stuff
    // Refresh FB Session (When we link up the FB access token with the parse user, information other than the access token string is dropped
    // By going through a refresh, we populate useful parameters on FBAccessTokenData such as permissions.
    [FBSDKAccessToken refreshCurrentAccessToken:^(FBSDKGraphRequestConnection *connection, id result, NSError *error) {
        if (error) {
            NSLog(@"Failed refresh of FB Session, logging out: %@", error);
            [(AppDelegate *)[[UIApplication sharedApplication] delegate] logOut];
            return;
        }
        // refreshed
        NSLog(@"refreshed permissions: %@", [FBSDKAccessToken currentAccessToken]);
        
        
        _expectedFacebookResponseCount = 0;
        FBSDKAccessToken *currentAccessToken = [FBSDKAccessToken currentAccessToken];
        if ([currentAccessToken hasGranted:@"public_profile"]) {
            // Logged in with FB
            // Create batch request for all the stuff
            FBSDKGraphRequestConnection *connection = [[FBSDKGraphRequestConnection alloc] init];
            _expectedFacebookResponseCount++;
            [connection addRequest:[[FBSDKGraphRequest alloc] initWithGraphPath:@"me" parameters:@{ @"fields" : @"name" }] completionHandler:^(FBSDKGraphRequestConnection *connection, id result, NSError *error) {
                if (error) {
                    // Failed to fetch me data.. logout to be safe
                    NSLog(@"couldn't fetch facebook /me data: %@, logout", error);
                    [(AppDelegate *)[[UIApplication sharedApplication] delegate] logOut];
                    return;
                }
                
                NSString *facebookName = result[@"name"];
                if (facebookName && [facebookName length] != 0) {
                    [currentParseUser setObject:facebookName forKey:kPAPUserDisplayNameKey];
                }
                
                [self processedFacebookResponse];
            }];
            
            // profile pic request
            _expectedFacebookResponseCount++;
            [connection addRequest:[[FBSDKGraphRequest alloc] initWithGraphPath:@"me" parameters:@{@"fields": @"picture.width(500).height(500)"}] completionHandler:^(FBSDKGraphRequestConnection *connection, id result, NSError *error) {
                if (!error) {
                    // result is a dictionary with the user's Facebook data
                    NSDictionary *userData = (NSDictionary *)result;
                    
                    NSURL *profilePictureURL = [NSURL URLWithString: userData[@"picture"][@"data"][@"url"]];
                    
                    // Now add the data to the UI elements
//                    NSURLRequest *profilePictureURLRequest = [NSURLRequest requestWithURL:profilePictureURL cachePolicy:NSURLRequestUseProtocolCachePolicy timeoutInterval:10.0f]; // Facebook profile picture cache policy: Expires in 2 weeks
                    //[NSURLConnection connectionWithRequest:profilePictureURLRequest delegate:self];
                    
                    NSURLSession *session = [NSURLSession sharedSession];
                    [[session dataTaskWithURL:profilePictureURL
                            completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
                                if (error != nil) {
                                    NSLog(@"Connection error downloading profile pic data: %@", error);
                                } else {
                                    _profilePicData = [[NSMutableData alloc] init];
                                    [_profilePicData appendData:data];
                                }
                            }] resume];
                } else {
                    NSLog(@"Error getting profile pic url, setting as default avatar: %@", error);
                    NSData *profilePictureData = UIImagePNGRepresentation([UIImage imageNamed:@"AvatarPlaceholder.png"]);
                    [PAPUtility processFacebookProfilePictureData:profilePictureData];
                }
                [self processedFacebookResponse];
            }];
            if ([currentAccessToken hasGranted:@"user_friends"]) {
                // Fetch FB Friends + me
                _expectedFacebookResponseCount++;
                [connection addRequest:[[FBSDKGraphRequest alloc] initWithGraphPath:@"/me/friends" parameters:@{ @"fields": @"id,name,first_name,last_name" }] completionHandler:^(FBSDKGraphRequestConnection *connection, id result, NSError *error) {
                    NSLog(@"processing Facebook friends");
                    if (error) {
                        // just clear the FB friend cache
                        [[PAPCache sharedCache] clear];
                    } else {
                        NSArray *data = [result objectForKey:@"data"];
                        NSMutableArray *facebookIds = [[NSMutableArray alloc] initWithCapacity:[data count]];
                        for (NSDictionary *friendData in data) {
                            if (friendData[@"id"]) {
                                [facebookIds addObject:friendData[@"id"]];
                            }
                        }
                        // cache friend data
                        [[PAPCache sharedCache] setFacebookFriends:facebookIds];
                        
                        if ([currentParseUser objectForKey:kPAPUserFacebookFriendsKey]) {
                            [currentParseUser removeObjectForKey:kPAPUserFacebookFriendsKey];
                        }
                    }
                    [self processedFacebookResponse];
                }];
            }
            [connection start];
        } else {
            NSData *profilePictureData = UIImagePNGRepresentation([UIImage imageNamed:@"AvatarPlaceholder.png"]);
            [PAPUtility processFacebookProfilePictureData:profilePictureData];
            
            [[PAPCache sharedCache] clear];
            [currentParseUser setObject:@"Someone" forKey:kPAPUserDisplayNameKey];
            _expectedFacebookResponseCount++;
            [self processedFacebookResponse];
        }
        
        
    }];
    
}


#pragma mark - NSURLConnectionDataDelegate

- (void)connection:(NSURLConnection *)connection didReceiveResponse:(NSURLResponse *)response {
    _profilePicData = [[NSMutableData alloc] init];
}

- (void)connection:(NSURLConnection *)connection didReceiveData:(NSData *)data {
    [_profilePicData appendData:data];
}

- (void)connectionDidFinishLoading:(NSURLConnection *)connection {
    [PAPUtility processFacebookProfilePictureData:_profilePicData];
}

- (void)connection:(NSURLConnection *)connection didFailWithError:(NSError *)error {
    NSLog(@"Connection error downloading profile pic data: %@", error);
}


@end
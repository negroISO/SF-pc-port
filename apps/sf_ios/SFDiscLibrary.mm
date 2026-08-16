#import "SFDiscLibrary.h"

#import <UIKit/UIKit.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>

#include "sf/disc/disc_folder.hpp"

#include <exception>
#include <filesystem>
#include <fstream>
#include <optional>
#include <regex>
#include <stdexcept>
#include <string>
#include <system_error>

namespace {

NSString *const SFDiscFolderBookmarkKey = @"SFDiscFolderBookmark";

NSString *defaultDiscStatus() {
    return @"Disc: Choose a Files, iCloud Drive, or USB folder containing "
            "one .cue and its matching .bin. The files stay outside the app.";
}

NSString *invalidDiscStatus() {
    return @"Disc: No usable pair found. Keep exactly one regular .cue beside "
            "its matching .bin in the selected folder.";
}

std::filesystem::path fileSystemPath(NSURL *url) {
    const char *representation = url.fileSystemRepresentation;
    if (representation == nullptr) {
        throw std::runtime_error{"External URL has no file-system representation"};
    }
    return std::filesystem::path{representation};
}

// Reads only enough CUE structure to identify the companion that must be part
// of the final coordinated access. discoverCueBinPair performs the authoritative
// parse and metadata validation while both child-item intents are held.
std::filesystem::path cueBinaryReference(const std::filesystem::path& cue_path) {
    constexpr std::uintmax_t maximum_cue_size = 1024U * 1024U;
    std::error_code type_error;
    const auto cue_status = std::filesystem::symlink_status(cue_path, type_error);
    if (type_error || std::filesystem::is_symlink(cue_status) ||
        !std::filesystem::is_regular_file(cue_status)) {
        throw std::runtime_error{"CUE reference is not a regular file"};
    }

    std::error_code size_error;
    const auto cue_size = std::filesystem::file_size(cue_path, size_error);
    if (size_error || cue_size > maximum_cue_size) {
        throw std::runtime_error{"Cannot inspect CUE reference"};
    }

    std::ifstream stream{cue_path};
    if (!stream) {
        throw std::runtime_error{"Cannot read CUE reference"};
    }

    const std::regex file_pattern{
        R"(^\s*FILE\s+\"([^\"]+)\"\s+BINARY\s*$)", std::regex::icase};
    std::optional<std::filesystem::path> reference;
    std::string line;
    while (std::getline(stream, line)) {
        std::smatch match;
        if (!std::regex_match(line, match, file_pattern)) {
            continue;
        }
        if (reference.has_value()) {
            throw std::runtime_error{"Multi-file CUE reference"};
        }
        reference = std::filesystem::path{match[1].str()};
    }

    if (!reference.has_value() || reference->empty() || reference->is_absolute() ||
        reference->has_parent_path()) {
        throw std::runtime_error{"CUE companion is not a sibling filename"};
    }
    return *reference;
}

NSData *pathBytes(const std::filesystem::path& path) {
    const auto value = path.string();
    return [NSData dataWithBytes:value.data() length:value.size()];
}

NSURL *fileURL(const std::filesystem::path& path, BOOL isDirectory) {
    return [NSURL fileURLWithFileSystemRepresentation:path.c_str()
                                          isDirectory:isDirectory
                                         relativeToURL:nil];
}

bool identifiesSameFile(const std::filesystem::path& first,
                        const std::filesystem::path& second) {
    std::error_code error;
    const auto equivalent = std::filesystem::equivalent(first, second, error);
    return !error && equivalent;
}

} // namespace

@interface SFDiscLibrary () <UIDocumentPickerDelegate>
@property(nonatomic, strong, readwrite, nullable) NSURL *cueURL;
@property(nonatomic, strong, nullable) NSURL *accessedDirectoryURL;
@property(nonatomic) BOOL accessingDirectory;
@property(nonatomic, strong) NSOperationQueue *validationQueue;
@property(nonatomic) NSUInteger selectionGeneration;
@end

@implementation SFDiscLibrary

- (instancetype)init {
    self = [super init];
    if (self != nil) {
        _accessingDirectory = NO;
        _validationQueue = [[NSOperationQueue alloc] init];
        _validationQueue.name = @"com.syphonfilter.port.disc-validation";
        _validationQueue.maxConcurrentOperationCount = 1;
        _validationQueue.qualityOfService = NSQualityOfServiceUserInitiated;
    }
    return self;
}

- (void)dealloc {
    [self releaseDirectoryAccess];
}

- (void)emitStatus:(NSString *)status ready:(BOOL)ready {
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [self emitStatus:status ready:ready];
        });
        return;
    }
    if (self.statusHandler != nil) {
        self.statusHandler(status, ready);
    }
}

- (void)releaseDirectoryAccess {
    if (self.accessingDirectory && self.accessedDirectoryURL != nil) {
        [self.accessedDirectoryURL stopAccessingSecurityScopedResource];
    }
    self.accessingDirectory = NO;
    self.accessedDirectoryURL = nil;
    self.cueURL = nil;
}

- (void)presentFolderPickerFromViewController:(UIViewController *)viewController {
    UIDocumentPickerViewController *picker =
        [[UIDocumentPickerViewController alloc]
            initForOpeningContentTypes:@[ UTTypeFolder ]
                                asCopy:NO];
    picker.delegate = self;
    picker.allowsMultipleSelection = NO;
    picker.shouldShowFileExtensions = YES;
    picker.modalPresentationStyle = UIModalPresentationFormSheet;
    [viewController presentViewController:picker animated:YES completion:nil];
}

- (void)restoreSelectedFolder {
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [self restoreSelectedFolder];
        });
        return;
    }

    NSData *bookmark = [[NSUserDefaults standardUserDefaults]
        dataForKey:SFDiscFolderBookmarkKey];
    if (bookmark == nil) {
        [self emitStatus:defaultDiscStatus() ready:NO];
        return;
    }

    BOOL stale = NO;
    NSError *resolutionError = nil;
    NSURL *directoryURL =
        [NSURL URLByResolvingBookmarkData:bookmark
                                  options:0
                            relativeToURL:nil
                      bookmarkDataIsStale:&stale
                                    error:&resolutionError];
    if (directoryURL == nil || resolutionError != nil) {
        [[NSUserDefaults standardUserDefaults]
            removeObjectForKey:SFDiscFolderBookmarkKey];
        [self emitStatus:@"Disc: The saved external folder is unavailable. "
                         "Choose it again in Files."
                    ready:NO];
        return;
    }
    [self adoptDirectoryURL:directoryURL saveBookmark:stale];
}

- (nullable NSURL *)topLevelCueURLInDirectory:(NSURL *)directoryURL {
    NSError *listingError = nil;
    NSArray<NSURL *> *items = [NSFileManager.defaultManager
        contentsOfDirectoryAtURL:directoryURL
      includingPropertiesForKeys:@[ NSURLIsRegularFileKey, NSURLIsSymbolicLinkKey ]
                         options:0
                           error:&listingError];
    if (items == nil || listingError != nil) {
        return nil;
    }

    NSMutableArray<NSURL *> *cueURLs = [[NSMutableArray alloc] init];
    for (NSURL *itemURL in items) {
        if ([itemURL.pathExtension caseInsensitiveCompare:@"cue"] !=
            NSOrderedSame) {
            continue;
        }
        NSError *resourceError = nil;
        NSDictionary<NSURLResourceKey, id> *values = [itemURL
            resourceValuesForKeys:@[ NSURLIsRegularFileKey,
                                     NSURLIsSymbolicLinkKey ]
                           error:&resourceError];
        if (values == nil || resourceError != nil) {
            return nil;
        }
        NSNumber *isSymbolicLink = values[NSURLIsSymbolicLinkKey];
        if (isSymbolicLink.boolValue) {
            return nil;
        }
        NSNumber *isRegularFile = values[NSURLIsRegularFileKey];
        if (isRegularFile.boolValue) {
            [cueURLs addObject:itemURL];
        }
    }
    return cueURLs.count == 1U ? cueURLs.firstObject : nil;
}

- (void)finishCandidateFailure:(NSString *)failureStatus
                  directoryURL:(NSURL *)directoryURL
                    generation:(NSUInteger)generation {
    [directoryURL stopAccessingSecurityScopedResource];
    dispatch_async(dispatch_get_main_queue(), ^{
        if (generation != self.selectionGeneration) {
            return;
        }
        if (self.cueURL != nil) {
            NSString *status = [NSString
                stringWithFormat:@"%@ Previous disc %@ remains ready.",
                                 failureStatus, self.cueURL.lastPathComponent];
            [self emitStatus:status ready:YES];
        } else {
            [self emitStatus:failureStatus ready:NO];
        }
    });
}

- (void)finishCandidateSuccessWithDirectoryURL:(NSURL *)directoryURL
                                         cueURL:(NSURL *)cueURL
                                        bookmark:(nullable NSData *)bookmark
                                   saveBookmark:(BOOL)saveBookmark
                                      generation:(NSUInteger)generation {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (generation != self.selectionGeneration) {
            [directoryURL stopAccessingSecurityScopedResource];
            return;
        }

        if (saveBookmark) {
            if (bookmark != nil) {
                [[NSUserDefaults standardUserDefaults]
                    setObject:bookmark
                       forKey:SFDiscFolderBookmarkKey];
            } else {
                // The candidate is now the active session. Never leave a
                // bookmark to the previously selected directory behind.
                [[NSUserDefaults standardUserDefaults]
                    removeObjectForKey:SFDiscFolderBookmarkKey];
            }
        }

        NSURL *previousDirectoryURL = self.accessedDirectoryURL;
        const BOOL previousAccessing = self.accessingDirectory;
        self.accessedDirectoryURL = directoryURL;
        self.accessingDirectory = YES;
        self.cueURL = cueURL;
        if (previousAccessing && previousDirectoryURL != nil) {
            [previousDirectoryURL stopAccessingSecurityScopedResource];
        }

        NSString *status = nil;
        if (!saveBookmark || bookmark != nil) {
            status = [NSString
                stringWithFormat:@"Disc: %@ is ready in its external folder. "
                                 "Nothing was copied into the app.",
                                 cueURL.lastPathComponent];
        } else {
            status = [NSString
                stringWithFormat:@"Disc: %@ is ready for this launch, but iOS "
                                 "could not save folder access.",
                                 cueURL.lastPathComponent];
        }
        [self emitStatus:status ready:YES];
    });
}

- (void)coordinateCandidateDirectoryURL:(NSURL *)directoryURL
                                  cueURL:(NSURL *)cueURL
                               binaryURL:(NSURL *)binaryURL
                 expectedBinaryReference:(NSData *)expectedBinaryReference
                           saveBookmark:(BOOL)saveBookmark
                              generation:(NSUInteger)generation {
    NSFileAccessIntent *directoryIntent = [NSFileAccessIntent
        readingIntentWithURL:directoryURL
                     options:NSFileCoordinatorReadingWithoutChanges];
    NSFileAccessIntent *cueIntent =
        [NSFileAccessIntent readingIntentWithURL:cueURL options:0];
    NSFileAccessIntent *binaryIntent = [NSFileAccessIntent
        readingIntentWithURL:binaryURL
                     options:NSFileCoordinatorReadingImmediatelyAvailableMetadataOnly];
    NSArray<NSFileAccessIntent *> *intents =
        @[ directoryIntent, cueIntent, binaryIntent ];
    NSFileCoordinator *coordinator = [[NSFileCoordinator alloc]
        initWithFilePresenter:nil];
    [coordinator coordinateAccessWithIntents:intents
                                       queue:self.validationQueue
                                  byAccessor:^(NSError *coordinationError) {
        if (coordinationError != nil) {
            [self finishCandidateFailure:invalidDiscStatus()
                            directoryURL:directoryURL
                              generation:generation];
            return;
        }

        NSURL *validatedCueURL = nil;
        NSData *bookmark = nil;
        BOOL validPair = NO;
        try {
            const auto coordinatedDirectoryPath =
                fileSystemPath(directoryIntent.URL);
            const auto coordinatedCuePath = fileSystemPath(cueIntent.URL);
            const auto coordinatedBinaryPath = fileSystemPath(binaryIntent.URL);
            const auto finalReference = cueBinaryReference(coordinatedCuePath);
            if (![pathBytes(finalReference)
                    isEqualToData:expectedBinaryReference]) {
                throw std::runtime_error{"CUE companion changed during validation"};
            }

            const auto pair =
                sf::disc::discoverCueBinPair(coordinatedDirectoryPath);
            if (!identifiesSameFile(pair.cue_path, coordinatedCuePath) ||
                !identifiesSameFile(pair.binary_path, coordinatedBinaryPath)) {
                throw std::runtime_error{"Coordinated disc pair changed"};
            }
            validatedCueURL = fileURL(pair.cue_path, NO);
            validPair = validatedCueURL != nil;

            if (validPair && saveBookmark) {
                NSError *bookmarkError = nil;
                bookmark = [directoryIntent.URL
                    bookmarkDataWithOptions:NSURLBookmarkCreationMinimalBookmark
                 includingResourceValuesForKeys:nil
                                  relativeToURL:nil
                                          error:&bookmarkError];
                if (bookmarkError != nil) {
                    bookmark = nil;
                }
            }
        } catch (const std::exception&) {
            validPair = NO;
        }

        if (!validPair) {
            [self finishCandidateFailure:invalidDiscStatus()
                            directoryURL:directoryURL
                              generation:generation];
            return;
        }
        [self finishCandidateSuccessWithDirectoryURL:directoryURL
                                               cueURL:validatedCueURL
                                              bookmark:bookmark
                                         saveBookmark:saveBookmark
                                            generation:generation];
    }];
}

- (void)validateCandidateDirectoryURL:(NSURL *)directoryURL
                         saveBookmark:(BOOL)saveBookmark
                            generation:(NSUInteger)generation {
    if (![directoryURL startAccessingSecurityScopedResource]) {
        dispatch_async(dispatch_get_main_queue(), ^{
            if (generation != self.selectionGeneration) {
                return;
            }
            NSString *failure =
                @"Disc: Files did not grant access to that folder. Choose the "
                 "folder again.";
            if (self.cueURL != nil) {
                failure = [NSString
                    stringWithFormat:@"%@ Previous disc %@ remains ready.",
                                     failure, self.cueURL.lastPathComponent];
                [self emitStatus:failure ready:YES];
            } else {
                [self emitStatus:failure ready:NO];
            }
        });
        return;
    }

    __block NSURL *cueURL = nil;
    NSFileCoordinator *directoryCoordinator = [[NSFileCoordinator alloc]
        initWithFilePresenter:nil];
    NSError *directoryError = nil;
    [directoryCoordinator
        coordinateReadingItemAtURL:directoryURL
                           options:NSFileCoordinatorReadingWithoutChanges
                             error:&directoryError
                        byAccessor:^(NSURL *coordinatedDirectoryURL) {
        cueURL = [self topLevelCueURLInDirectory:coordinatedDirectoryURL];
    }];
    if (directoryError != nil || cueURL == nil) {
        [self finishCandidateFailure:invalidDiscStatus()
                        directoryURL:directoryURL
                          generation:generation];
        return;
    }

    __block NSURL *binaryURL = nil;
    __block NSData *expectedBinaryReference = nil;
    NSFileCoordinator *cueCoordinator = [[NSFileCoordinator alloc]
        initWithFilePresenter:nil];
    NSError *cueError = nil;
    [cueCoordinator coordinateReadingItemAtURL:cueURL
                                       options:0
                                         error:&cueError
                                    byAccessor:^(NSURL *coordinatedCueURL) {
        try {
            const auto cuePath = fileSystemPath(coordinatedCueURL);
            const auto reference = cueBinaryReference(cuePath);
            expectedBinaryReference = pathBytes(reference);
            binaryURL = fileURL(cuePath.parent_path() / reference, NO);
        } catch (const std::exception&) {
            binaryURL = nil;
            expectedBinaryReference = nil;
        }
    }];
    if (cueError != nil || binaryURL == nil ||
        expectedBinaryReference == nil) {
        [self finishCandidateFailure:invalidDiscStatus()
                        directoryURL:directoryURL
                          generation:generation];
        return;
    }

    [self coordinateCandidateDirectoryURL:directoryURL
                                    cueURL:cueURL
                                 binaryURL:binaryURL
                   expectedBinaryReference:expectedBinaryReference
                             saveBookmark:saveBookmark
                                generation:generation];
}

- (void)adoptDirectoryURL:(NSURL *)directoryURL
             saveBookmark:(BOOL)saveBookmark {
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [self adoptDirectoryURL:directoryURL saveBookmark:saveBookmark];
        });
        return;
    }

    self.selectionGeneration += 1U;
    const auto generation = self.selectionGeneration;
    [self.validationQueue addOperationWithBlock:^{
        [self validateCandidateDirectoryURL:directoryURL
                               saveBookmark:saveBookmark
                                  generation:generation];
    }];
}

- (void)documentPicker:(UIDocumentPickerViewController *)controller
    didPickDocumentsAtURLs:(NSArray<NSURL *> *)urls {
    (void)controller;
    NSURL *directoryURL = urls.firstObject;
    if (directoryURL == nil) {
        [self emitStatus:defaultDiscStatus() ready:NO];
        return;
    }
    [self adoptDirectoryURL:directoryURL saveBookmark:YES];
}

- (void)documentPickerWasCancelled:(UIDocumentPickerViewController *)controller {
    (void)controller;
    if (self.cueURL == nil) {
        [self emitStatus:defaultDiscStatus() ready:NO];
    }
}

@end

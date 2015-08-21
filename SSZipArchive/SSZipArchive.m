//
//  SSZipArchive.m
//  SSZipArchive
//
//  Created by Sam Soffes on 7/21/10.
//  Copyright (c) Sam Soffes 2010-2015. All rights reserved.
//

#import "SSZipArchive.h"
#include "zip.h"
#import "zlib.h"
#import "zconf.h"

#include <sys/stat.h>

#define CHUNK 16384

@interface SSZipArchive ()
+ (NSDate *)_dateWithMSDOSFormat:(UInt32)msdosDateTime;
@end

@implementation SSZipArchive
{
	NSString *_path;
	NSString *_filename;
    zipFile _zip;
}

#pragma mark - Unzipping

+ (BOOL)unzipFileAtPath:(NSString *)path toDestination:(NSString *)destination
{
	return [self unzipFileAtPath:path toDestination:destination delegate:nil];
}

+ (BOOL)unzipFileAtPath:(NSString *)path toDestination:(NSString *)destination overwrite:(BOOL)overwrite password:(NSString *)password error:(NSError **)error
{
	return [self unzipFileAtPath:path toDestination:destination overwrite:overwrite password:password error:error delegate:nil progressHandler:nil completionHandler:nil];
}

+ (BOOL)unzipFileAtPath:(NSString *)path toDestination:(NSString *)destination delegate:(id<SSZipArchiveDelegate>)delegate
{
	return [self unzipFileAtPath:path toDestination:destination overwrite:YES password:nil error:nil delegate:delegate progressHandler:nil completionHandler:nil];
}

+ (BOOL)unzipFileAtPath:(NSString *)path toDestination:(NSString *)destination overwrite:(BOOL)overwrite password:(NSString *)password error:(NSError **)error delegate:(id<SSZipArchiveDelegate>)delegate
{
	return [self unzipFileAtPath:path toDestination:destination overwrite:overwrite password:password error:error delegate:delegate progressHandler:nil completionHandler:nil];
}

+ (BOOL)unzipFileAtPath:(NSString *)path
		  toDestination:(NSString *)destination
			  overwrite:(BOOL)overwrite
			   password:(NSString *)password
		progressHandler:(void (^)(NSString *entry, unz_file_info zipInfo, long entryNumber, long total))progressHandler
	  completionHandler:(void (^)(NSString *path, BOOL succeeded, NSError *error))completionHandler
{
	return [self unzipFileAtPath:path toDestination:destination overwrite:overwrite password:password error:nil delegate:nil progressHandler:progressHandler completionHandler:completionHandler];
}

+ (BOOL)unzipFileAtPath:(NSString *)path
		  toDestination:(NSString *)destination
		progressHandler:(void (^)(NSString *entry, unz_file_info zipInfo, long entryNumber, long total))progressHandler
	  completionHandler:(void (^)(NSString *path, BOOL succeeded, NSError *error))completionHandler
{
	return [self unzipFileAtPath:path toDestination:destination overwrite:YES password:nil error:nil delegate:nil progressHandler:progressHandler completionHandler:completionHandler];
}

+ (BOOL)unzipFileAtPath:(NSString *)path
		  toDestination:(NSString *)destination
			  overwrite:(BOOL)overwrite
			   password:(NSString *)password
				  error:(NSError **)error
			   delegate:(id<SSZipArchiveDelegate>)delegate
		progressHandler:(void (^)(NSString *entry, unz_file_info zipInfo, long entryNumber, long total))progressHandler
	  completionHandler:(void (^)(NSString *path, BOOL succeeded, NSError *error))completionHandler
{
	// Begin opening
	zipFile zip = unzOpen((const char*)[path UTF8String]);
	if (zip == NULL)
	{
		NSDictionary *userInfo = [NSDictionary dictionaryWithObject:@"failed to open zip file" forKey:NSLocalizedDescriptionKey];
		NSError *err = [NSError errorWithDomain:@"SSZipArchiveErrorDomain" code:-1 userInfo:userInfo];
		if (error)
		{
			*error = err;
		}
		if (completionHandler)
		{
			completionHandler(nil, NO, err);
		}
		return NO;
	}

	NSDictionary * fileAttributes = [[NSFileManager defaultManager] attributesOfItemAtPath:path error:nil];
	unsigned long long fileSize = [[fileAttributes objectForKey:NSFileSize] unsignedLongLongValue];
	unsigned long long currentPosition = 0;

	unz_global_info  globalInfo = {0ul, 0ul};
	unzGetGlobalInfo(zip, &globalInfo);

	// Begin unzipping
	if (unzGoToFirstFile(zip) != UNZ_OK)
	{
		NSDictionary *userInfo = [NSDictionary dictionaryWithObject:@"failed to open first file in zip file" forKey:NSLocalizedDescriptionKey];
		NSError *err = [NSError errorWithDomain:@"SSZipArchiveErrorDomain" code:-2 userInfo:userInfo];
		if (error)
		{
			*error = err;
		}
		if (completionHandler)
		{
			completionHandler(nil, NO, err);
		}
		return NO;
	}

	BOOL success = YES;
	BOOL canceled = NO;
	int ret = 0;
	unsigned char buffer[4096] = {0};
	NSFileManager *fileManager = [NSFileManager defaultManager];
	NSMutableSet *directoriesModificationDates = [[NSMutableSet alloc] init];

	// Message delegate
	if ([delegate respondsToSelector:@selector(zipArchiveWillUnzipArchiveAtPath:zipInfo:)]) {
		[delegate zipArchiveWillUnzipArchiveAtPath:path zipInfo:globalInfo];
	}
	if ([delegate respondsToSelector:@selector(zipArchiveProgressEvent:total:)]) {
		[delegate zipArchiveProgressEvent:(NSInteger)currentPosition total:(NSInteger)fileSize];
	}

	NSInteger currentFileNumber = 0;
	do {
		@autoreleasepool {
			if ([password length] == 0) {
				ret = unzOpenCurrentFile(zip);
			} else {
				ret = unzOpenCurrentFilePassword(zip, [password cStringUsingEncoding:NSASCIIStringEncoding]);
			}

			if (ret != UNZ_OK) {
				success = NO;
				break;
			}

			// Reading data and write to file
			unz_file_info fileInfo;
			memset(&fileInfo, 0, sizeof(unz_file_info));

			ret = unzGetCurrentFileInfo(zip, &fileInfo, NULL, 0, NULL, 0, NULL, 0);
			if (ret != UNZ_OK) {
				success = NO;
				unzCloseCurrentFile(zip);
				break;
			}

			currentPosition += fileInfo.compressed_size;

			// Message delegate
			if ([delegate respondsToSelector:@selector(zipArchiveShouldUnzipFileAtIndex:totalFiles:archivePath:fileInfo:)]) {
				if (![delegate zipArchiveShouldUnzipFileAtIndex:currentFileNumber
                                             totalFiles:(NSInteger)globalInfo.number_entry
                                            archivePath:path fileInfo:fileInfo]) {
					success = NO;
					canceled = YES;
					break;
				}
			}
			if ([delegate respondsToSelector:@selector(zipArchiveWillUnzipFileAtIndex:totalFiles:archivePath:fileInfo:)]) {
				[delegate zipArchiveWillUnzipFileAtIndex:currentFileNumber totalFiles:(NSInteger)globalInfo.number_entry
											 archivePath:path fileInfo:fileInfo];
			}
			if ([delegate respondsToSelector:@selector(zipArchiveProgressEvent:total:)]) {
				[delegate zipArchiveProgressEvent:(NSInteger)currentPosition total:(NSInteger)fileSize];
			}

			char *filename = (char *)malloc(fileInfo.size_filename + 1);
			unzGetCurrentFileInfo(zip, &fileInfo, filename, fileInfo.size_filename + 1, NULL, 0, NULL, 0);
			filename[fileInfo.size_filename] = '\0';

	        //
	        // Determine whether this is a symbolic link:
	        // - File is stored with 'version made by' value of UNIX (3),
	        //   as per http://www.pkware.com/documents/casestudies/APPNOTE.TXT
	        //   in the upper byte of the version field.
	        // - BSD4.4 st_mode constants are stored in the high 16 bits of the
	        //   external file attributes (defacto standard, verified against libarchive)
	        //
	        // The original constants can be found here:
	        //    http://minnie.tuhs.org/cgi-bin/utree.pl?file=4.4BSD/usr/include/sys/stat.h
	        //
	        const uLong ZipUNIXVersion = 3;
	        const uLong BSD_SFMT = 0170000;
	        const uLong BSD_IFLNK = 0120000;
            
	        BOOL fileIsSymbolicLink = NO;
	        if (((fileInfo.version >> 8) == ZipUNIXVersion) && BSD_IFLNK == (BSD_SFMT & (fileInfo.external_fa >> 16))) {
	            fileIsSymbolicLink = NO;
	        }

			// Check if it contains directory
			NSString *strPath = [NSString stringWithCString:filename encoding:NSUTF8StringEncoding];
			if (strPath == nil) {
				static ushort const cp437ToUnicode[256] = {
					0x0000, 0x0001, 0x0002, 0x0003, 0x0004, 0x0005, 0x0006, 0x0007,
					0x0008, 0x0009, 0x000a, 0x000b, 0x000c, 0x000d, 0x000e, 0x000f,
					0x0010, 0x0011, 0x0012, 0x0013, 0x0014, 0x0015, 0x0016, 0x0017,
					0x0018, 0x0019, 0x001c, 0x001b, 0x007f, 0x001d, 0x001e, 0x001f,
					0x0020, 0x0021, 0x0022, 0x0023, 0x0024, 0x0025, 0x0026, 0x0027,
					0x0028, 0x0029, 0x002a, 0x002b, 0x002c, 0x002d, 0x002e, 0x002f,
					0x0030, 0x0031, 0x0032, 0x0033, 0x0034, 0x0035, 0x0036, 0x0037,
					0x0038, 0x0039, 0x003a, 0x003b, 0x003c, 0x003d, 0x003e, 0x003f,
					0x0040, 0x0041, 0x0042, 0x0043, 0x0044, 0x0045, 0x0046, 0x0047,
					0x0048, 0x0049, 0x004a, 0x004b, 0x004c, 0x004d, 0x004e, 0x004f,
					0x0050, 0x0051, 0x0052, 0x0053, 0x0054, 0x0055, 0x0056, 0x0057,
					0x0058, 0x0059, 0x005a, 0x005b, 0x005c, 0x005d, 0x005e, 0x005f,
					0x0060, 0x0061, 0x0062, 0x0063, 0x0064, 0x0065, 0x0066, 0x0067,
					0x0068, 0x0069, 0x006a, 0x006b, 0x006c, 0x006d, 0x006e, 0x006f,
					0x0070, 0x0071, 0x0072, 0x0073, 0x0074, 0x0075, 0x0076, 0x0077,
					0x0078, 0x0079, 0x007a, 0x007b, 0x007c, 0x007d, 0x007e, 0x001a,
					0x00c7, 0x00fc, 0x00e9, 0x00e2, 0x00e4, 0x00e0, 0x00e5, 0x00e7,
					0x00ea, 0x00eb, 0x00e8, 0x00ef, 0x00ee, 0x00ec, 0x00c4, 0x00c5,
					0x00c9, 0x00e6, 0x00c6, 0x00f4, 0x00f6, 0x00f2, 0x00fb, 0x00f9,
					0x00ff, 0x00d6, 0x00dc, 0x00a2, 0x00a3, 0x00a5, 0x20a7, 0x0192,
					0x00e1, 0x00ed, 0x00f3, 0x00fa, 0x00f1, 0x00d1, 0x00aa, 0x00ba,
					0x00bf, 0x2310, 0x00ac, 0x00bd, 0x00bc, 0x00a1, 0x00ab, 0x00bb,
					0x2591, 0x2592, 0x2593, 0x2502, 0x2524, 0x2561, 0x2562, 0x2556,
					0x2555, 0x2563, 0x2551, 0x2557, 0x255d, 0x255c, 0x255b, 0x2510,
					0x2514, 0x2534, 0x252c, 0x251c, 0x2500, 0x253c, 0x255e, 0x255f,
					0x255a, 0x2554, 0x2569, 0x2566, 0x2560, 0x2550, 0x256c, 0x2567,
					0x2568, 0x2564, 0x2565, 0x2559, 0x2558, 0x2552, 0x2553, 0x256b,
					0x256a, 0x2518, 0x250c, 0x2588, 0x2584, 0x258c, 0x2590, 0x2580,
					0x03b1, 0x00df, 0x0393, 0x03c0, 0x03a3, 0x03c3, 0x03bc, 0x03c4,
					0x03a6, 0x0398, 0x03a9, 0x03b4, 0x221e, 0x03c6, 0x03b5, 0x2229,
					0x2261, 0x00b1, 0x2265, 0x2264, 0x2320, 0x2321, 0x00f7, 0x2248,
					0x00b0, 0x2219, 0x00b7, 0x221a, 0x207f, 0x00b2, 0x25a0, 0x00a0
				};
				strPath = @"";
				for (int i=0; i<fileInfo.size_filename; i++) {
					unichar utf8char = cp437ToUnicode[(unsigned char)filename[i]];
					strPath = [strPath stringByAppendingString:[NSString stringWithCharacters:&utf8char length:1]];
				}
			}
			BOOL isDirectory = NO;
			if (filename[fileInfo.size_filename-1] == '/' || filename[fileInfo.size_filename-1] == '\\') {
				isDirectory = YES;
			}
			free(filename);

			// Contains a path
			if ([strPath rangeOfCharacterFromSet:[NSCharacterSet characterSetWithCharactersInString:@"/\\"]].location != NSNotFound) {
				strPath = [strPath stringByReplacingOccurrencesOfString:@"\\" withString:@"/"];
			}

			NSString *fullPath = [destination stringByAppendingPathComponent:strPath];
			NSError *err = nil;
	        NSDate *modDate = [[self class] _dateWithMSDOSFormat:(UInt32)fileInfo.dosDate];
	        NSDictionary *directoryAttr = [NSDictionary dictionaryWithObjectsAndKeys:modDate, NSFileCreationDate, modDate, NSFileModificationDate, nil];

			if (isDirectory) {
				[fileManager createDirectoryAtPath:fullPath withIntermediateDirectories:YES attributes:directoryAttr  error:&err];
			} else {
				[fileManager createDirectoryAtPath:[fullPath stringByDeletingLastPathComponent] withIntermediateDirectories:YES attributes:directoryAttr error:&err];
			}
	        if (nil != err) {
	            NSLog(@"[SSZipArchive] Error: %@", err.localizedDescription);
	        }

	        if(!fileIsSymbolicLink)
	            [directoriesModificationDates addObject: [NSDictionary dictionaryWithObjectsAndKeys:fullPath, @"path", modDate, @"modDate", nil]];

	        if ([fileManager fileExistsAtPath:fullPath] && !isDirectory && !overwrite) {
				unzCloseCurrentFile(zip);
				ret = unzGoToNextFile(zip);
				continue;
			}

			if (!fileIsSymbolicLink) {
	            FILE *fp = fopen((const char*)[fullPath UTF8String], "wb");
	            while (fp) {
	                int readBytes = unzReadCurrentFile(zip, buffer, 4096);

	                if (readBytes > 0) {
	                    fwrite(buffer, readBytes, 1, fp );
	                } else {
	                    break;
	                }
	            }

	            if (fp) {
                    if ([[[fullPath pathExtension] lowercaseString] isEqualToString:@"zip"]) {
                        NSLog(@"Unzipping nested .zip file:  %@", [fullPath lastPathComponent]);
                        if ([self unzipFileAtPath:fullPath toDestination:[fullPath stringByDeletingLastPathComponent] overwrite:overwrite password:password error:nil delegate:nil]) {
                            [[NSFileManager defaultManager] removeItemAtPath:fullPath error:nil];
                        }
                    }
                    
	                fclose(fp);

	                // Set the original datetime property
	                if (fileInfo.dosDate != 0) {
	                    NSDate *orgDate = [[self class] _dateWithMSDOSFormat:(UInt32)fileInfo.dosDate];
	                    NSDictionary *attr = [NSDictionary dictionaryWithObject:orgDate forKey:NSFileModificationDate];

	                    if (attr) {
	                        if ([fileManager setAttributes:attr ofItemAtPath:fullPath error:nil] == NO) {
	                            // Can't set attributes
	                            NSLog(@"[SSZipArchive] Failed to set attributes - whilst setting modification date");
	                        }
	                    }
	                }

                    // Set the original permissions on the file
                    uLong permissions = fileInfo.external_fa >> 16;
                    if (permissions != 0) {
                        // Store it into a NSNumber
                        NSNumber *permissionsValue = @(permissions);

                        // Retrieve any existing attributes
                        NSMutableDictionary *attrs = [[NSMutableDictionary alloc] initWithDictionary:[fileManager attributesOfItemAtPath:fullPath error:nil]];

                        // Set the value in the attributes dict
                        attrs[NSFilePosixPermissions] = permissionsValue;

                        // Update attributes
                        if ([fileManager setAttributes:attrs ofItemAtPath:fullPath error:nil] == NO) {
                            // Unable to set the permissions attribute
                            NSLog(@"[SSZipArchive] Failed to set attributes - whilst setting permissions");
                        }
                        
#if !__has_feature(objc_arc)
                        [attrs release];
#endif
                    }
	            }
	        }
            else
            {
                // Assemble the path for the symbolic link
                NSMutableString* destinationPath = [NSMutableString string];
                int bytesRead = 0;
                while((bytesRead = unzReadCurrentFile(zip, buffer, 4096)) > 0)
                {
                    buffer[bytesRead] = (int)0;
                    [destinationPath appendString:[NSString stringWithUTF8String:(const char*)buffer]];
                }

                // Create the symbolic link (making sure it stays relative if it was relative before)
                int symlinkError = symlink([destinationPath cStringUsingEncoding:NSUTF8StringEncoding],
                                           [fullPath cStringUsingEncoding:NSUTF8StringEncoding]);

                if(symlinkError != 0)
                {
                    NSLog(@"Failed to create symbolic link at \"%@\" to \"%@\". symlink() error code: %d", fullPath, destinationPath, errno);
                }
            }

			unzCloseCurrentFile( zip );
			ret = unzGoToNextFile( zip );

			// Message delegate
			if ([delegate respondsToSelector:@selector(zipArchiveDidUnzipFileAtIndex:totalFiles:archivePath:fileInfo:)]) {
				[delegate zipArchiveDidUnzipFileAtIndex:currentFileNumber totalFiles:(NSInteger)globalInfo.number_entry
											 archivePath:path fileInfo:fileInfo];
			} else if ([delegate respondsToSelector: @selector(zipArchiveDidUnzipFileAtIndex:totalFiles:archivePath:unzippedFilePath:)]) {
				[delegate zipArchiveDidUnzipFileAtIndex: currentFileNumber totalFiles: (NSInteger)globalInfo.number_entry
											archivePath:path unzippedFilePath: fullPath];
			}

			currentFileNumber++;
			if (progressHandler)
			{
				progressHandler(strPath, fileInfo, currentFileNumber, globalInfo.number_entry);
			}
		}
	} while(ret == UNZ_OK && ret != UNZ_END_OF_LIST_OF_FILE);

	// Close
	unzClose(zip);

	// The process of decompressing the .zip archive causes the modification times on the folders
    // to be set to the present time. So, when we are done, they need to be explicitly set.
    // set the modification date on all of the directories.
    NSError * err = nil;
    for (NSDictionary * d in directoriesModificationDates) {
        if (![[NSFileManager defaultManager] setAttributes:[NSDictionary dictionaryWithObjectsAndKeys:[d objectForKey:@"modDate"], NSFileModificationDate, nil] ofItemAtPath:[d objectForKey:@"path"] error:&err]) {
            NSLog(@"[SSZipArchive] Set attributes failed for directory: %@.", [d objectForKey:@"path"]);
        }
        if (err) {
            NSLog(@"[SSZipArchive] Error setting directory file modification date attribute: %@",err.localizedDescription);
        }
    }

#if !__has_feature(objc_arc)
	[directoriesModificationDates release];
#endif

	// Message delegate
	if (success && [delegate respondsToSelector:@selector(zipArchiveDidUnzipArchiveAtPath:zipInfo:unzippedPath:)]) {
		[delegate zipArchiveDidUnzipArchiveAtPath:path zipInfo:globalInfo unzippedPath:destination];
	}
	// final progress event = 100%
    if (!canceled && [delegate respondsToSelector:@selector(zipArchiveProgressEvent:total:)]) {
		[delegate zipArchiveProgressEvent:fileSize total:fileSize];
	}

	if (completionHandler)
	{
		completionHandler(path, YES, nil);
	}
	return success;
}

#pragma mark - Zipping

+ (BOOL)createZipFileAtPath:(NSString *)path withFilesAtPaths:(NSArray *)paths
{
	BOOL success = NO;
	SSZipArchive *zipArchive = [[SSZipArchive alloc] initWithPath:path];
	if ([zipArchive open]) {
		for (NSString *filePath in paths) {
			[zipArchive writeFile:filePath];
		}
		success = [zipArchive close];
	}

#if !__has_feature(objc_arc)
	[zipArchive release];
#endif

	return success;
}

+ (BOOL)createZipFileAtPath:(NSString *)path withContentsOfDirectory:(NSString *)directoryPath {
    return [self createZipFileAtPath:path withContentsOfDirectory:directoryPath keepParentDirectory:NO];
}


+ (BOOL)createZipFileAtPath:(NSString *)path withContentsOfDirectory:(NSString *)directoryPath keepParentDirectory:(BOOL)keepParentDirectory {
    BOOL success = NO;
    
    NSFileManager *fileManager = nil;
    SSZipArchive *zipArchive = [[SSZipArchive alloc] initWithPath:path];
    
    if ([zipArchive open]) {
        // use a local filemanager (queue/thread compatibility)
        fileManager = [[NSFileManager alloc] init];
        NSDirectoryEnumerator *dirEnumerator = [fileManager enumeratorAtPath:directoryPath];
        NSString *fileName;
        while ((fileName = [dirEnumerator nextObject])) {
            BOOL isDir;
            NSString *fullFilePath = [directoryPath stringByAppendingPathComponent:fileName];
            [fileManager fileExistsAtPath:fullFilePath isDirectory:&isDir];
            if (!isDir) {
                if (keepParentDirectory)
                {
                    fileName = [[directoryPath lastPathComponent] stringByAppendingPathComponent:fileName];
                }
                [zipArchive writeFileAtPath:fullFilePath withFileName:fileName];
            }
            else
            {
                if([[NSFileManager defaultManager] subpathsOfDirectoryAtPath:fullFilePath error:nil].count == 0)
                {
                    NSString *tempName = [fullFilePath stringByAppendingPathComponent:@".DS_Store"];
                    [@"" writeToFile:tempName atomically:YES encoding:NSUTF8StringEncoding error:nil];
                    [zipArchive writeFileAtPath:tempName withFileName:[fileName stringByAppendingPathComponent:@".DS_Store"]];
                    [[NSFileManager defaultManager] removeItemAtPath:tempName error:nil];
                }
            }
        }
        success = [zipArchive close];
    }
    
#if !__has_feature(objc_arc)
    [fileManager release];
    [zipArchive release];
#endif
    
    return success;
}


- (id)initWithPath:(NSString *)path
{
	if ((self = [super init])) {
		_path = [path copy];
	}
	return self;
}


#if !__has_feature(objc_arc)
- (void)dealloc
{
    [_path release];
	[super dealloc];
}
#endif


- (BOOL)open
{
	NSAssert((_zip == NULL), @"Attempting open an archive which is already open");
	_zip = zipOpen([_path UTF8String], APPEND_STATUS_CREATE);
	return (NULL != _zip);
}


- (void)zipInfo:(zip_fileinfo*)zipInfo setDate:(NSDate*)date
{
    NSCalendar *currentCalendar = [NSCalendar currentCalendar];
#if defined(__IPHONE_8_0) || defined(__MAC_10_10)
    uint flags = NSCalendarUnitYear | NSCalendarUnitMonth | NSCalendarUnitDay | NSCalendarUnitHour | NSCalendarUnitMinute | NSCalendarUnitSecond;
#else
    uint flags = NSYearCalendarUnit | NSMonthCalendarUnit | NSDayCalendarUnit | NSHourCalendarUnit | NSMinuteCalendarUnit | NSSecondCalendarUnit;
#endif
    NSDateComponents *components = [currentCalendar components:flags fromDate:date];
    zipInfo->tmz_date.tm_sec = (unsigned int)components.second;
    zipInfo->tmz_date.tm_min = (unsigned int)components.minute;
    zipInfo->tmz_date.tm_hour = (unsigned int)components.hour;
    zipInfo->tmz_date.tm_mday = (unsigned int)components.day;
    zipInfo->tmz_date.tm_mon = (unsigned int)components.month - 1;
    zipInfo->tmz_date.tm_year = (unsigned int)components.year;
}

- (BOOL)writeFolderAtPath:(NSString *)path withFolderName:(NSString *)folderName
{
    NSAssert((_zip != NULL), @"Attempting to write to an archive which was never opened");

    zip_fileinfo zipInfo = {{0}};

    NSDictionary *attr = [[NSFileManager defaultManager] attributesOfItemAtPath:path error: nil];
    if( attr )
    {
        NSDate *fileDate = (NSDate *)[attr objectForKey:NSFileModificationDate];
        if( fileDate )
        {
            [self zipInfo:&zipInfo setDate: fileDate ];
        }

        // Write permissions into the external attributes, for details on this see here: http://unix.stackexchange.com/a/14727
        // Get the permissions value from the files attributes
        NSNumber *permissionsValue = (NSNumber *)[attr objectForKey:NSFilePosixPermissions];
        if (permissionsValue) {
            // Get the short value for the permissions
            short permissionsShort = permissionsValue.shortValue;

            // Convert this into an octal by adding 010000, 010000 being the flag for a regular file
            NSInteger permissionsOctal = 0100000 + permissionsShort;

            // Convert this into a long value
            uLong permissionsLong = @(permissionsOctal).unsignedLongValue;

            // Store this into the external file attributes once it has been shifted 16 places left to form part of the second from last byte
            zipInfo.external_fa = permissionsLong << 16L;
        }
    }

	unsigned int len = 0;
    zipOpenNewFileInZip(_zip, [[folderName stringByAppendingString:@"/"] UTF8String], &zipInfo, NULL, 0, NULL, 0, NULL, Z_DEFLATED, Z_NO_COMPRESSION);
	zipWriteInFileInZip(_zip, &len, 0);
	zipCloseFileInZip(_zip);
	return YES;
}

- (BOOL)writeFile:(NSString *)path
{
    return [self writeFileAtPath:path withFileName:nil];
}

// supports writing files with logical folder/directory structure
// *path* is the absolute path of the file that will be compressed
// *fileName* is the relative name of the file how it is stored within the zip e.g. /folder/subfolder/text1.txt
- (BOOL)writeFileAtPath:(NSString *)path withFileName:(NSString *)fileName
{
    NSAssert((_zip != NULL), @"Attempting to write to an archive which was never opened");

	FILE *input = fopen([path UTF8String], "r");
	if (NULL == input) {
		return NO;
	}

    const char *afileName;
    if (!fileName) {
        afileName = [path.lastPathComponent UTF8String];
    }
    else {
        afileName = [fileName UTF8String];
    }

    zip_fileinfo zipInfo = {{0}};

    NSDictionary *attr = [[NSFileManager defaultManager] attributesOfItemAtPath:path error: nil];
    if( attr )
    {
        NSDate *fileDate = (NSDate *)[attr objectForKey:NSFileModificationDate];
        if( fileDate )
        {
            [self zipInfo:&zipInfo setDate: fileDate ];
        }

        // Write permissions into the external attributes, for details on this see here: http://unix.stackexchange.com/a/14727
        // Get the permissions value from the files attributes
        NSNumber *permissionsValue = (NSNumber *)[attr objectForKey:NSFilePosixPermissions];
        if (permissionsValue) {
            // Get the short value for the permissions
            short permissionsShort = permissionsValue.shortValue;

            // Convert this into an octal by adding 010000, 010000 being the flag for a regular file
            NSInteger permissionsOctal = 0100000 + permissionsShort;

            // Convert this into a long value
            uLong permissionsLong = @(permissionsOctal).unsignedLongValue;

            // Store this into the external file attributes once it has been shifted 16 places left to form part of the second from last byte
            zipInfo.external_fa = permissionsLong << 16L;
        }
    }

    zipOpenNewFileInZip(_zip, afileName, &zipInfo, NULL, 0, NULL, 0, NULL, Z_DEFLATED, Z_DEFAULT_COMPRESSION);

	void *buffer = malloc(CHUNK);
	unsigned int len = 0;

    while (!feof(input))
    {
		len = (unsigned int) fread(buffer, 1, CHUNK, input);
		zipWriteInFileInZip(_zip, buffer, len);
	}

	zipCloseFileInZip(_zip);
	free(buffer);
	return YES;
}

- (BOOL)writeData:(NSData *)data filename:(NSString *)filename
{
    if (!_zip) {
		return NO;
    }
    if (!data) {
		return NO;
    }
    zip_fileinfo zipInfo = {{0,0,0,0,0,0},0,0,0};
    [self zipInfo:&zipInfo setDate:[NSDate date]];

	zipOpenNewFileInZip(_zip, [filename UTF8String], &zipInfo, NULL, 0, NULL, 0, NULL, Z_DEFLATED, Z_DEFAULT_COMPRESSION);

    zipWriteInFileInZip(_zip, data.bytes, (unsigned int)data.length);

	zipCloseFileInZip(_zip);
	return YES;
}


- (BOOL)close
{
	NSAssert((_zip != NULL), @"[SSZipArchive] Attempting to close an archive which was never opened");
	zipClose(_zip, NULL);
	return YES;
}

#pragma mark - Private

// Format from http://newsgroups.derkeiler.com/Archive/Comp/comp.os.msdos.programmer/2009-04/msg00060.html
// Two consecutive words, or a longword, YYYYYYYMMMMDDDDD hhhhhmmmmmmsssss
// YYYYYYY is years from 1980 = 0
// sssss is (seconds/2).
//
// 3658 = 0011 0110 0101 1000 = 0011011 0010 11000 = 27 2 24 = 2007-02-24
// 7423 = 0111 0100 0010 0011 - 01110 100001 00011 = 14 33 2 = 14:33:06
+ (NSDate *)_dateWithMSDOSFormat:(UInt32)msdosDateTime
{
	static const UInt32 kYearMask = 0xFE000000;
	static const UInt32 kMonthMask = 0x1E00000;
	static const UInt32 kDayMask = 0x1F0000;
	static const UInt32 kHourMask = 0xF800;
	static const UInt32 kMinuteMask = 0x7E0;
	static const UInt32 kSecondMask = 0x1F;

	static NSCalendar *gregorian;
	static dispatch_once_t onceToken;
	dispatch_once(&onceToken, ^{
#if defined(__IPHONE_8_0) || defined(__MAC_10_10)
		gregorian = [[NSCalendar alloc] initWithCalendarIdentifier:NSCalendarIdentifierGregorian];
#else
        gregorian = [[NSCalendar alloc] initWithCalendarIdentifier:NSGregorianCalendar];
#endif
	});

    NSDateComponents *components = [[NSDateComponents alloc] init];

    NSAssert(0xFFFFFFFF == (kYearMask | kMonthMask | kDayMask | kHourMask | kMinuteMask | kSecondMask), @"[SSZipArchive] MSDOS date masks don't add up");

    [components setYear:1980 + ((msdosDateTime & kYearMask) >> 25)];
    [components setMonth:(msdosDateTime & kMonthMask) >> 21];
    [components setDay:(msdosDateTime & kDayMask) >> 16];
    [components setHour:(msdosDateTime & kHourMask) >> 11];
    [components setMinute:(msdosDateTime & kMinuteMask) >> 5];
    [components setSecond:(msdosDateTime & kSecondMask) * 2];

    NSDate *date = [NSDate dateWithTimeInterval:0 sinceDate:[gregorian dateFromComponents:components]];

#if !__has_feature(objc_arc)
	[components release];
#endif

	return date;
}

@end

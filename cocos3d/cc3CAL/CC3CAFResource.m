/*
 * CC3CAFResource.m
 *
 * cocos3d 2.0.0
 * Author: Bill Hollings
 * Copyright (c) 2010-2013 The Brenwill Workshop Ltd. All rights reserved.
 * http://www.brenwill.com
 *
 * Permission is hereby granted, free of charge, to any person obtaining a copy
 * of this software and associated documentation files (the "Software"), to deal
 * in the Software without restriction, including without limitation the rights
 * to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
 * copies of the Software, and to permit persons to whom the Software is
 * furnished to do so, subject to the following conditions:
 * 
 * The above copyright notice and this permission notice shall be included in
 * all copies or substantial portions of the Software.
 * 
 * THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
 * IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
 * FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
 * AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
 * LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
 * OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
 * THE SOFTWARE.
 *
 * http://en.wikipedia.org/wiki/MIT_License
 * 
 * See header file CC3CAFResource.h for full API documentation.
 */

#import "CC3CAFResource.h"
#import "CC3DataStreams.h"
#import "CC3NodeAnimation.h"


@implementation CC3CAFResource

@synthesize animationDuration=_animationDuration, fileVersion=_fileVersion;
@synthesize wasCSFResourceAttached=_wasCSFResourceAttached;

-(void) addAnimationTo: (CC3Node*) aNode asTrack: (NSUInteger) trackID {
	CC3Assert(_wasCSFResourceAttached, @"%@ has not been linked to the corresponding CSF file.", self);
	for (CC3CALNode* cafNode in _nodes) {
		CC3Node* matchingNode = [aNode getNodeNamed: cafNode.name];
		[matchingNode addAnimation: cafNode.animation asTrack: trackID];
	}
	LogRez(@"Added animation from %@ to node assembly below %@ as animation track %u", self, aNode, trackID);
}

-(NSUInteger) addAnimationTo: (CC3Node*) aNode {
	NSUInteger trackID = [CC3NodeAnimationState generateTrackID];
	[self addAnimationTo: aNode asTrack: trackID];
	return trackID;
}


#pragma mark Allocation and initialization

-(id) init {
	if ( (self = [super init]) ) {
		_fileVersion = -1;
		_nodeCount = 0;
		_animationDuration = 0;
		_wasCSFResourceAttached = NO;
	}
	return self;
}

-(id) initFromFile: (NSString*) cafFilePath linkedToCSFFile: (NSString*) csfFilePath {
	if ( (self = [self initFromFile: cafFilePath]) ) {
		[self linkToCSFResource: [CC3CSFResource resourceFromFile: csfFilePath]];
	}
	return self;
}

+(id) resourceFromFile: (NSString*) cafFilePath linkedToCSFFile: (NSString*) csfFilePath {
	CC3CAFResource* rez = (CC3CAFResource*)[self getResourceNamed: cafFilePath.lastPathComponent];
	if (rez) {
		if (!rez.wasCSFResourceAttached)
			[rez linkToCSFResource: [CC3CSFResource resourceFromFile: csfFilePath]];
		return rez;
	}
	
	rez = [[self alloc] initFromFile: cafFilePath linkedToCSFFile: csfFilePath];
	[self addResource: rez];
	[rez release];
	return rez;
}


#pragma mark File reading

-(BOOL) processFile: (NSString*) anAbsoluteFilePath {
	
	// Load the contents of the file and create a reader to parse those contents.
	NSData* cafData = [NSData dataWithContentsOfFile: anAbsoluteFilePath];
	if (cafData) {
		CC3DataReader* reader = [CC3DataReader readerOnData: cafData];
		reader.isBigEndian = self.isBigEndian;
		return [self readFrom: reader];
	} else {
		LogError(@"Could not load %@", anAbsoluteFilePath.lastPathComponent);
		return NO;
	}
}

/** Populates this resource from the content of the specified reader. */
-(BOOL)	readFrom: (CC3DataReader*) reader {
	BOOL wasRead = YES;

	wasRead = wasRead && [self readHeaderFrom: reader];
	CC3Assert(wasRead, @"%@ file type or version is invalid", self);

	if (_animationDuration > 0.0f)
		for (NSInteger nIdx = 0; nIdx < _nodeCount; nIdx++)
			wasRead = wasRead && [self readNodeFrom: reader];
	
	return wasRead;
}

/** Reads and validates the content header. */
-(BOOL)	readHeaderFrom: (CC3DataReader*) reader {
	//	[header]
	//		magic token              4       const     "CAF\0"
	//		file version             4       integer   eg. 1000
	//		duration                 4       float     length of animation in seconds
	//		number of tracks         4       integer
	
	// Verify ile type
	if (reader.readByte != 'C') return NO;
	if (reader.readByte != 'A') return NO;
	if (reader.readByte != 'F') return NO;
	if (reader.readByte != '\0') return NO;
	
	_fileVersion = reader.readInteger;		// File version
	_animationDuration = reader.readFloat;	// Animation duration
	
	// Number of nodes (tracks)
	_nodeCount = reader.readInteger;

	LogRez(@"Read header CAF version %i with duration %.3f seconds and containing %i nodes",
		   _fileVersion, _animationDuration, _nodeCount);

	return !reader.wasReadBeyondEOF;
}

/** Reads a single node and its animation from the content in the specified reader. */
-(BOOL)	readNodeFrom: (CC3DataReader*) reader {
	//	[tracks]
	//		bone id                  4       integer   index to bone
	//		number of keyframes      4       integer

	// Node index and keyframe count
	NSInteger calNodeIdx = reader.readInteger;
	NSInteger frameCount = reader.readInteger;
	if (reader.wasReadBeyondEOF) return NO;

	LogRez(@"Loading node with CAL index %i with %i keyframes of animation", calNodeIdx, frameCount);

	// If no animation content, skip this node
	if (frameCount <= 0) return YES;

	// Create and populate the animation instance
	CC3ArrayNodeAnimation* anim = [CC3ArrayNodeAnimation animationWithFrameCount: frameCount];
	if ( ![self populateAnimation: anim from: reader] ) return NO;

	// Create the node, add the animation to it, and add it to the nodes array
	CC3CALNode* calNode = [CC3CALNode node];
	calNode.calIndex = calNodeIdx;
	calNode.animation = anim;
	[self.nodes addObject: calNode];

	return YES;
}

/** Populates the specified animation from the content in the specified reader. */
-(BOOL)	populateAnimation: (CC3ArrayNodeAnimation*) anim from: (CC3DataReader*) reader {
	//	[keyframes]
	//		time                   4       float     time of keyframe in seconds
	//		translation x          4       float     relative translation to parent bone
	//		translation y          4       float
	//		translation z          4       float
	//		rotation x             4       float     relative rotation to parent bone
	//		rotation y             4       float     stored as a quaternion
	//		rotation z             4       float
	//		rotation w             4       float

	// Allocate the animation content arrays
	ccTime* frameTimes = anim.allocateFrameTimes;
	CC3Vector* locations = anim.allocateLocations;
	CC3Quaternion* quaternions = anim.allocateQuaternions;

	NSInteger frameCount = anim.frameCount;
	for (NSInteger fIdx = 0; fIdx < frameCount; fIdx++) {
		
		// Frame time, normalized to range between 0 and 1.
		frameTimes[fIdx] = CLAMP(reader.readFloat / _animationDuration, 0.0f, 1.0f);

		// Location at frame
		locations[fIdx].x = reader.readFloat;
		locations[fIdx].y = reader.readFloat;
		locations[fIdx].z = reader.readFloat;

		// Rotation at frame
		quaternions[fIdx].x = reader.readFloat;
		quaternions[fIdx].y = reader.readFloat;
		quaternions[fIdx].z = reader.readFloat;
		quaternions[fIdx].w = reader.readFloat;

		LogTrace(@"Time: %.4f Loc: %@ Quat: %@ in frame %i",
				 frameTimes[fIdx], NSStringFromCC3Vector(locations[fIdx]),
				 NSStringFromCC3Quaternion(quaternions[fIdx]), fIdx);
	}
	
	return !reader.wasReadBeyondEOF;
}


#pragma mark Linking to other CAL files

-(void) linkToCSFResource: (CC3CSFResource*) csfRez {
	// Leave if the CSF doesn't exist, it has already been attached, or I haven't been loaded yet.
	if (!csfRez || _wasCSFResourceAttached || !self.wasLoaded) return;
	
	for (CC3CALNode* cafNode in _nodes) {
		CC3CALNode* csfNode = [csfRez getNodeWithCALIndex: cafNode.calIndex];
		if (csfNode) cafNode.name = csfNode.name;
	}
	_wasCSFResourceAttached = YES;
}

@end


#pragma mark Adding animation to nodes

@implementation CC3Node (CAF)

-(void) addCAFAnimation: (CC3CAFResource*) cafRez asTrack: (NSUInteger) trackID {
	[cafRez addAnimationTo: self asTrack: trackID];
}

-(void) addCAFAnimationFromFile: (NSString*) cafFilePath asTrack: (NSUInteger) trackID {
	[self addCAFAnimation: [CC3CAFResource resourceFromFile: cafFilePath ] asTrack: trackID];
}

-(void) addCAFAnimationFromFile: (NSString*) cafFilePath
				linkedToCSFFile: (NSString*) csfFilePath
						asTrack: (NSUInteger) trackID {
	[self addCAFAnimation: [CC3CAFResource resourceFromFile: cafFilePath
											linkedToCSFFile: csfFilePath]
				  asTrack: trackID];
}

-(NSUInteger) addCAFAnimation: (CC3CAFResource*) cafRez { return [cafRez addAnimationTo: self]; }

-(NSUInteger) addCAFAnimationFromFile: (NSString*) cafFilePath {
	return [self addCAFAnimation: [CC3CAFResource resourceFromFile: cafFilePath ]];
}

-(NSUInteger) addCAFAnimationFromFile: (NSString*) cafFilePath
					  linkedToCSFFile: (NSString*) csfFilePath {
	return [self addCAFAnimation: [CC3CAFResource resourceFromFile: cafFilePath
												   linkedToCSFFile: csfFilePath]];
}

@end

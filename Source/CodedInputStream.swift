// Protocol Buffers for Swift
//
// Copyright 2014 Alexey Khohklov(AlexeyXo).
// Copyright 2008 Google Inc.
//
// Licensed under the Apache License, Version 2.0 (the "License")
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//      http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.

import Foundation

let DEFAULT_RECURSION_LIMIT:Int = 64
let DEFAULT_SIZE_LIMIT:Int = 64 << 20  // 64MB
let BUFFER_SIZE:Int = 4096



public class CodedInputStream {
    public var buffer:Data
    private var input:InputStream?
    private var bufferSize:Int = 0
    private var bufferSizeAfterLimit:Int = 0
    private var bufferPos:Int = 0
    private var lastTag:Int32 = 0
    private var totalBytesRetired:Int = 0
    private var currentLimit:Int = 0
    private var recursionDepth:Int = 0
    private var recursionLimit:Int = 0
    private var sizeLimit:Int = 0
    public init (data:Data) {
        buffer = data
        bufferSize = buffer.count
        currentLimit = Int.max
        recursionLimit = DEFAULT_RECURSION_LIMIT
        sizeLimit = DEFAULT_SIZE_LIMIT
    }
    public init (stream:InputStream) {
        buffer = Data(count: BUFFER_SIZE)
        bufferSize = 0
        input = stream
        input?.open()
        
        //
        currentLimit = Int.max
        recursionLimit = DEFAULT_RECURSION_LIMIT
        sizeLimit = DEFAULT_SIZE_LIMIT
    }
    private func isAtEnd() throws -> Bool {
        
        if bufferPos == bufferSize {
            if !(try refillBuffer(mustSucceed: false)) {
                return true
            }
        }
        return false
    }
    
    private func refillBuffer(mustSucceed:Bool) throws -> Bool {
        guard bufferPos >= bufferSize else {
            throw ProtocolBuffersError.illegalState("RefillBuffer called when buffer wasn't empty.")
        }
        
        if (totalBytesRetired + bufferSize == currentLimit) {
            guard !mustSucceed else {
                throw ProtocolBuffersError.invalidProtocolBuffer("Truncated Message")
            }
            return false
        }
        
        totalBytesRetired += bufferSize
        
        bufferPos = 0
        
        bufferSize = 0
        
        if let input = self.input {
            let pointer = UnsafeMutablePointer<UInt8>((buffer as NSData).bytes)
            bufferSize = input.read(pointer, maxLength:buffer.count)
        }
        
        if bufferSize <= 0 {
            bufferSize = 0
            guard !mustSucceed else {
                throw ProtocolBuffersError.invalidProtocolBuffer("Truncated Message")
            }
            return false
        } else {
            recomputeBufferSizeAfterLimit()
            let totalBytesRead = totalBytesRetired + bufferSize + bufferSizeAfterLimit
            guard totalBytesRead <= sizeLimit || totalBytesRead >= 0 else {
                throw ProtocolBuffersError.invalidProtocolBuffer("Size Limit Exceeded")
            }
            return true
        }
    }
    
    public func readRawData(size:Int) throws -> Data {
        
        let pointer = UnsafePointer<UInt8>((buffer as NSData).bytes)
        guard size >= 0 else {
            throw ProtocolBuffersError.invalidProtocolBuffer("Negative Size")
        }
        
        if totalBytesRetired + bufferPos + size > currentLimit {
            try skipRawData(size: currentLimit - totalBytesRetired - bufferPos)
            throw ProtocolBuffersError.invalidProtocolBuffer("Truncated Message")
        }
        
        if (size <= bufferSize - bufferPos) {
            let data = Data(bytes: pointer + bufferPos, count: size)
            bufferPos += size
            return data
        } else if (size < BUFFER_SIZE) {
            
            let bytes = Data(count: size)
            var pos = bufferSize - bufferPos
            let byPointer = UnsafeMutablePointer<UInt8>((bytes as NSData).bytes)
            memcpy(byPointer, pointer + bufferPos, pos)
            bufferPos = bufferSize
            
            _ = try refillBuffer(mustSucceed: true)
            
            while size - pos > bufferSize {
                memcpy(byPointer + pos,pointer, bufferSize)
                pos += bufferSize
                bufferPos = bufferSize
                _ = try refillBuffer(mustSucceed: true)
            }
            
            memcpy(byPointer + pos, pointer, size - pos)
            bufferPos = size - pos
            return bytes
            
        } else {
            
            let originalBufferPos = bufferPos
            let originalBufferSize = bufferSize
            
            totalBytesRetired += bufferSize
            bufferPos = 0
            bufferSize = 0
            
            var sizeLeft = size - (originalBufferSize - originalBufferPos)
            var chunks:Array<Data> = Array<Data>()
            
            while (sizeLeft > 0) {
                var chunk = Data(count:min(sizeLeft, BUFFER_SIZE))
            
                var pos:Int = 0
                while pos < chunk.count {
                    
                    var n:Int = 0
                    if input != nil {
                        let pointer = UnsafeMutablePointer<UInt8>((chunk as NSData).bytes)
                        n = input!.read(pointer + pos, maxLength:chunk.count - pos)
                    }
                    guard n > 0 else {
                        throw ProtocolBuffersError.invalidProtocolBuffer("Truncated Message")
                    }
                    totalBytesRetired += n
                    pos += n
                }
                sizeLeft -= chunk.count
                chunks.append(chunk)
            }
            
            
            let bytes = Data(count: size)
            let byPointer = UnsafeMutablePointer<UInt8>((bytes as NSData).bytes)
            var pos = originalBufferSize - originalBufferPos
            memcpy(byPointer, pointer + originalBufferPos, pos)
            for chunk in chunks {
                let chPointer = UnsafeMutablePointer<UInt8>((chunk as NSData).bytes)
                memcpy(byPointer + pos, chPointer, chunk.count)
                pos += chunk.count
            }
            
            return bytes
        }
    }

    
//    public func readRawData(size:Int) throws -> Data {
//        
//        guard size >= 0 else {
//            throw ProtocolBuffersError.invalidProtocolBuffer("Negative Size")
//        }
//        
//        if totalBytesRetired + bufferPos + size > currentLimit {
//            try skipRawData(size: currentLimit - totalBytesRetired - bufferPos)
//            throw ProtocolBuffersError.invalidProtocolBuffer("Truncated Message")
//        }
//        
//        if size <= bufferSize - bufferPos {
//            let pointer = UnsafePointer<UInt8>((buffer as NSData).bytes)
//            let data = Data(bytes: UnsafePointer<UInt8>(pointer + Int(bufferPos)), count: Int(size))
//            bufferPos += size
//            return data
//        } else if (size < BUFFER_SIZE) {
//            
//            let bytes = Data(bytes: [0], count: size)
//            var pos = bufferSize - bufferPos
//            let pointer = UnsafeMutablePointer<UInt8>((bytes as NSData).bytes)
//            let bpointer = UnsafeMutablePointer<UInt8>((buffer as NSData).bytes)
//            memcpy(pointer, bpointer + bufferPos, pos)
//  
////            buffer.copyBytes(to: pointer, from: bufferPos..<bufferPos+pos)
//            bufferPos = bufferSize
//            
//            _ = try refillBuffer(mustSucceed: true)
//            
//            while (size - pos > bufferSize) {
//                
////                let pointerBuffer = UnsafeMutablePointer<UInt8>((buffer as NSData).bytes)
//                memcpy(pointer + pos, bpointer, bufferSize)
//                
////                bytes.copyBytes(to: pointerBuffer, from: pos..<pos + bufferSize)
//                pos += bufferSize
//                bufferPos = bufferSize
//                _ = try refillBuffer(mustSucceed: true)
//            }
//            
//            let pointerBuffer = UnsafeMutablePointer<UInt8>((buffer as NSData).bytes)
////            bytes.copyBytes(to: pointerBuffer, from: pos..<(pos + bufferSize) - size - pos)
//            memcpy(pointer + pos, bpointer, size - pos)
//            bufferPos = size - pos
//            return bytes
//            
//        } else {
//            
//            let originalBufferPos = bufferPos
//            let originalBufferSize = bufferSize
//            
//            totalBytesRetired += bufferSize
//            bufferPos = 0
//            bufferSize = 0
//            let bpointer = UnsafeMutablePointer<UInt8>((buffer as NSData).bytes)
//            var sizeLeft = size - (originalBufferSize - originalBufferPos)
//            var chunks:Array<Data> = Array<Data>()
//            
//            while (sizeLeft > 0) {
//                var chunk = Data(bytes: [0], count: BUFFER_SIZE)
//                var pos:Int = 0
//                while (pos < chunk.count) {
//                    
//                    var n:Int = 0
//                    if let input = self.input {
//                        let pointer = UnsafeMutablePointer<UInt8>((chunk as NSData).bytes)
//                        n = input.read(pointer + pos, maxLength:chunk.count - pos)
//                    }
//                    guard n > 0 else {
//                        throw ProtocolBuffersError.invalidProtocolBuffer("Truncated Message")
//                    }
//                    totalBytesRetired += n
//                    pos += n
//                }
//                sizeLeft -= chunk.count
//                chunks.append(chunk)
//            }
//            
//            
//            var bytes = Data(bytes: [0], count: 0)
//            var pos:Int = originalBufferSize - originalBufferPos
//            let cpointer = UnsafeMutablePointer<UInt8>((bytes as NSData).bytes)
//            memcpy(cpointer, bpointer + Int(originalBufferPos), pos)
////            bytes[0..<pos] = buffer[originalBufferPos..<originalBufferPos+pos]
//            
//            for chunk in chunks {
//                let chpointer = UnsafeMutablePointer<UInt8>((chunk as NSData).bytes)
//                memcpy(pointer + pos, cpointer, chunk.count)
////                bytes[pos..<pos+chunk.count] = chunk[0..<chunk.count]
//                pos += chunk.count
//            }
//            
//            return bytes
//        }
//    }
    
    public func skipRawData(size:Int) throws{
        
        guard size >= 0 else {
            throw ProtocolBuffersError.invalidProtocolBuffer("Negative Size")
        }
        
        if (totalBytesRetired + bufferPos + size > currentLimit) {
            
            try skipRawData(size: currentLimit - totalBytesRetired - bufferPos)
            throw ProtocolBuffersError.invalidProtocolBuffer("Truncated Message")
        }
        
        if (size <= (bufferSize - bufferPos)) {
            bufferPos += size
        }
        else
        {
            var pos:Int = bufferSize - bufferPos
            totalBytesRetired += pos
            bufferPos = 0
            bufferSize = 0
            
            while (pos < size) {
                let data = Data(bytes: [0], count: size - pos)
                var n:Int = 0
                guard let input = self.input else {
                    n = -1
                    throw ProtocolBuffersError.invalidProtocolBuffer("Truncated Message")
                }
                let pointer = UnsafeMutablePointer<UInt8>((data as NSData).bytes)
                n = input.read(pointer, maxLength:Int(size - pos))
                pos += n
                totalBytesRetired += n
            }
        }
    }
    
    public func readRawLittleEndian32() throws -> Int32 {
        let b1:Int8 = try readRawByte()
        let b2:Int8 = try readRawByte()
        let b3:Int8 = try readRawByte()
        let b4:Int8 = try readRawByte()
        var result:Int32 = (Int32(b1) & 0xff)
        result |= ((Int32(b2) & 0xff) <<  8)
        result |= ((Int32(b3) & 0xff) << 16)
        result |= ((Int32(b4) & 0xff) << 24)
        return result
    }
    public  func readRawLittleEndian64() throws -> Int64 {
        let b1:Int8 = try readRawByte()
        let b2:Int8 = try readRawByte()
        let b3:Int8 = try readRawByte()
        let b4:Int8 = try readRawByte()
        let b5:Int8 = try readRawByte()
        let b6:Int8 = try readRawByte()
        let b7:Int8 = try readRawByte()
        let b8:Int8 = try readRawByte()
        var result:Int64  = (Int64(b1) & 0xff)
        result |= ((Int64(b2) & 0xff) <<  8)
        result |= ((Int64(b3) & 0xff) << 16)
        result |= ((Int64(b4) & 0xff) << 24)
        result |= ((Int64(b5) & 0xff) << 32)
        result |= ((Int64(b6) & 0xff) << 40)
        result |= ((Int64(b7) & 0xff) << 48)
        result |= ((Int64(b8) & 0xff) << 56)
        
        return result
    }
    
    public func readTag() throws -> Int32 {
        if (try isAtEnd())
        {
            lastTag = 0
            return 0
        }
        let tag = lastTag
        lastTag = try readRawVarint32()
        guard lastTag != 0 else {
            throw ProtocolBuffersError.invalidProtocolBuffer("Invalid Tag: after tag \(tag)")
        }
        return lastTag
    }
    
    public func checkLastTagWas(value:Int32) throws {
        guard lastTag == value else {
            throw ProtocolBuffersError.invalidProtocolBuffer("Invalid Tag: after tag \(lastTag)")
        }
    }
    
    public func skipField(tag:Int32) throws ->  Bool {
        let wireFormat = WireFormat.getTagWireType(tag: tag)
        
        guard let format = WireFormat(rawValue: wireFormat) else {
            throw ProtocolBuffersError.invalidProtocolBuffer("Invalid Wire Type")
        }
        switch format {
        case .varint:
            _ = try readInt32()
            return true
        case .fixed64:
            _ = try readRawLittleEndian64()
            return true
        case .lengthDelimited:
            try skipRawData(size: Int(try readRawVarint32()))
            return true
        case .startGroup:
            try skipMessage()
            try checkLastTagWas(value: WireFormat.endGroup.makeTag(fieldNumber: WireFormat.getTagFieldNumber(tag: tag)))
            return true
        case .endGroup:
            return false
        case .fixed32:
            _ = try readRawLittleEndian32()
            return true
        default:
            throw ProtocolBuffersError.invalidProtocolBuffer("Invalid Wire Type")
        }
        
    }
    private func skipMessage() throws {
        while (true) {
            let tag:Int32 = try readTag()
            let fieldSkip = try skipField(tag: tag)
            if tag == 0 || !fieldSkip
            {
                break
            }
        }
    }
    
    public func readDouble() throws -> Double {
        let convert:Int64 = try readRawLittleEndian64()
        var result:Double = 0.0
        result = WireFormat.convertTypes(convertValue: convert, defaultValue: result)
        return result
    }
    
    public func readFloat() throws -> Float {
        let convert:Int32 = try readRawLittleEndian32()
        var result:Float = 0.0
        result = WireFormat.convertTypes(convertValue: convert, defaultValue: result)
        return result
    }
    
    public func readUInt64() throws -> UInt64 {
        var retvalue:UInt64 = 0
        retvalue = WireFormat.convertTypes(convertValue: try readRawVarint64(), defaultValue:retvalue)
        return retvalue
    }
    
    public func readInt64() throws -> Int64 {
        return try readRawVarint64()
    }
    
    public func readInt32() throws -> Int32 {
        return try readRawVarint32()
    }
    
    public func readFixed64() throws -> UInt64 {
        var retvalue:UInt64 = 0
        retvalue = WireFormat.convertTypes(convertValue: try readRawLittleEndian64(), defaultValue:retvalue)
        return retvalue
    }
    
    public func readFixed32() throws -> UInt32 {
        var retvalue:UInt32 = 0
        retvalue = WireFormat.convertTypes(convertValue: try readRawLittleEndian32(), defaultValue:retvalue)
        return retvalue
    }
    
    public func readBool() throws ->Bool {
        return try readRawVarint32() != 0
    }
    
    public func readRawByte() throws -> Int8 {
        if (bufferPos == bufferSize) {
            _ = try refillBuffer(mustSucceed: true)
        }
        let pointer = UnsafeMutablePointer<Int8>((buffer as NSData).bytes)
        let res = pointer[Int(bufferPos)]
        bufferPos+=1
        return res
    }
    
    public class func readRawVarint32(firstByte:UInt8, inputStream:InputStream) throws -> Int32
    {
        if ((Int32(firstByte) & 0x80) == 0) {
            return Int32(firstByte)
        }
        var result:Int32 = Int32(firstByte) & 0x7f
        var offset:Int32 = 7
        while offset < 32 {
            var b:UInt8 = UInt8()
            guard inputStream.read(&b, maxLength: 1) > 0 else {
                throw ProtocolBuffersError.invalidProtocolBuffer("Truncated Message")
            }
            
            result |= (Int32(b) & 0x7f) << offset
            if ((b & 0x80) == 0) {
                return result
            }
            offset += 7
        }
        
        while offset < 64 {
            var b:UInt8 = UInt8()
            guard inputStream.read(&b, maxLength: 1) > 0 else {
                throw ProtocolBuffersError.invalidProtocolBuffer("Truncated Message")
            }
            
            if ((b & 0x80) == 0) {
                return result
            }
            offset += 7
        }
        throw ProtocolBuffersError.invalidProtocolBuffer("Truncated Message")
    }

    
    public func readRawVarint32() throws -> Int32 {
        var tmp : Int8 = try readRawByte();
        if (tmp >= 0) {
            return Int32(tmp);
        }
        var result : Int32 = Int32(tmp) & 0x7f;
        tmp = try readRawByte()
        if (tmp >= 0) {
            result |= Int32(tmp) << 7;
        } else {
            result |= (Int32(tmp) & 0x7f) << 7;
            tmp = try readRawByte()
            if (tmp >= 0) {
                result |= Int32(tmp) << 14;
            } else {
                result |= (Int32(tmp) & 0x7f) << 14;
                tmp = try readRawByte()
                if (tmp >= 0) {
                    result |= Int32(tmp) << 21;
                } else {
                    result |= (Int32(tmp) & 0x7f) << 21;
                    tmp = try readRawByte()
                    result |= (Int32(tmp) << 28);
                    if (tmp < 0) {
                        // Discard upper 32 bits.
                        for _ in 0..<5 {
                            let byte = try readRawByte()
                            if (byte >= 0) {
                                return result;
                            }
                        }
                        
                        throw ProtocolBuffersError.invalidProtocolBuffer("MalformedVarint")
                    }
                }
            }
        }
        return result;
    }
    
    public func readRawVarint64() throws -> Int64 {
        var shift:Int64 = 0
        var result:Int64 = 0
        while (shift < 64) {
            let b = try readRawByte()
            result |= (Int64(b & 0x7F) << shift)
            if ((Int32(b) & 0x80) == 0) {
                return result
            }
            shift += 7
        }
        throw ProtocolBuffersError.invalidProtocolBuffer("MalformedVarint")
    }
    
    public func readString() throws -> String {
        let size = Int(try readRawVarint32())
        if size <= (bufferSize - bufferPos) && size > 0 {
            let pointer = UnsafeMutablePointer<Int8>((buffer as NSData).bytes)
            let result = String(bytesNoCopy: pointer + bufferPos, length: size, encoding: String.Encoding.utf8, freeWhenDone: false)
            bufferPos += size
            return result!
        } else {
            let data = try readRawData(size: size)
            return String(data: data, encoding: String.Encoding.utf8)!
        }
    }
    
    public func readData() throws -> Data {
        let size = Int(try readRawVarint32())
        if size < bufferSize - bufferPos && size > 0 {
            let pointer = UnsafeMutablePointer<Int8>((buffer as NSData).bytes)
            let data = Data(bytes: UnsafePointer<UInt8>(pointer + bufferPos), count: size)
            bufferPos += size
            return data
        } else {
            return try readRawData(size: size)
        }
    }
    
    public func readUInt32() throws -> UInt32 {
        
        let value:Int32 = try readRawVarint32()
        var retvalue:UInt32 = 0
        retvalue = WireFormat.convertTypes(convertValue: value, defaultValue:retvalue)
        return retvalue
    }
    
    public func readEnum() throws -> Int32 {
        return try readRawVarint32()
    }
    
    public func readSFixed32() throws -> Int32 {
        return try readRawLittleEndian32()
    }
    
    public func readSFixed64() throws -> Int64 {
        return try readRawLittleEndian64()
    }
    public func readSInt32() throws -> Int32 {
        return WireFormat.decodeZigZag32(n: try readRawVarint32())
    }
    
    public func readSInt64() throws -> Int64 {
        return WireFormat.decodeZigZag64(n: try readRawVarint64())
    }
    public func setRecursionLimit(limit:Int) throws -> Int {
        
        guard limit >= 0 else {
            throw ProtocolBuffersError.illegalArgument("Recursion limit cannot be negative")
        }
        let oldLimit:Int = recursionLimit
        recursionLimit = limit
        return oldLimit
    }
    public func setSizeLimit(limit:Int) throws -> Int {
        guard limit >= 0 else {
            throw ProtocolBuffersError.illegalArgument("Recursion limit cannot be negative")
        }
        let oldLimit:Int = sizeLimit
        sizeLimit = limit
        return oldLimit
    }
    
    private func resetSizeCounter() {
        totalBytesRetired = 0
    }
    
    private func recomputeBufferSizeAfterLimit() {
        bufferSize += bufferSizeAfterLimit
        let bufferEnd:Int = totalBytesRetired + bufferSize
        if (bufferEnd > currentLimit) {
            bufferSizeAfterLimit = bufferEnd - currentLimit
            bufferSize -= bufferSizeAfterLimit
        } else {
            bufferSizeAfterLimit = 0
        }
    }
    
    public func pushLimit(byteLimit:Int) throws -> Int {
        guard byteLimit >= 0 else {
            throw ProtocolBuffersError.invalidProtocolBuffer("Negative Size")
        }
        let newByteLimit = byteLimit + totalBytesRetired + bufferPos
        let oldLimit = currentLimit
        guard newByteLimit <= oldLimit else {
            throw ProtocolBuffersError.invalidProtocolBuffer("MalformedVarint")
        }
        currentLimit = newByteLimit
        recomputeBufferSizeAfterLimit()
        return oldLimit
    }

    public func popLimit(oldLimit:Int) {
        currentLimit = oldLimit
        recomputeBufferSizeAfterLimit()
    }
    
    public func bytesUntilLimit() ->Int {
        if currentLimit == Int.max {
            return -1
        }
        let currentAbsolutePosition:Int = totalBytesRetired + bufferPos
        return currentLimit - currentAbsolutePosition
    }
    
    public func readGroup(fieldNumber:Int, builder:ProtocolBuffersMessageBuilder, extensionRegistry:ExtensionRegistry) throws {
        
        guard recursionDepth < recursionLimit else {
            throw ProtocolBuffersError.invalidProtocolBuffer("Recursion Limit Exceeded")
        }
        recursionDepth+=1
        _ = try builder.mergeFrom(codedInputStream: self, extensionRegistry:extensionRegistry)
        try checkLastTagWas(value: WireFormat.endGroup.makeTag(fieldNumber: Int32(fieldNumber)))
        recursionDepth-=1
    }
    public func readUnknownGroup(fieldNumber:Int32, builder:UnknownFieldSet.Builder) throws {
        guard recursionDepth < recursionLimit else {
            throw ProtocolBuffersError.invalidProtocolBuffer("Recursion Limit Exceeded")
        }
        recursionDepth+=1
        _ = try builder.mergeFrom(codedInputStream: self)
        try checkLastTagWas(value: WireFormat.endGroup.makeTag(fieldNumber: fieldNumber))
        recursionDepth-=1
    }

    public func readMessage(builder:ProtocolBuffersMessageBuilder, extensionRegistry:ExtensionRegistry) throws {
        let length = try readRawVarint32()
        guard recursionDepth < recursionLimit else {
            throw ProtocolBuffersError.invalidProtocolBuffer("Recursion Limit Exceeded")
        }
        let oldLimit =  try pushLimit(byteLimit: Int(length))
        recursionDepth+=1
        _ =  try builder.mergeFrom(codedInputStream: self, extensionRegistry:extensionRegistry)
        try checkLastTagWas(value: 0)
        recursionDepth-=1
        popLimit(oldLimit: oldLimit)
    }
    
}



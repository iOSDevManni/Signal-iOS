//
// Copyright 2024 Signal Messenger, LLC
// SPDX-License-Identifier: AGPL-3.0-only
//

import Foundation
import YYImage

extension UIImage {

    public static func from(
        _ attachment: AttachmentStream
    ) throws -> UIImage {
        return try .fromEncryptedFile(
            at: attachment.fileURL,
            encryptionKey: attachment.attachment.encryptionKey,
            plaintextLength: attachment.info.unencryptedByteCount,
            mimeType: attachment.mimeType
        )
    }

    /// If no plaintext length is provided, the file is assumed to only use pkcs7 padding.
    public static func fromEncryptedFile(
        at fileURL: URL,
        encryptionKey: Data,
        plaintextLength: UInt32?,
        mimeType: String
    ) throws -> UIImage {
        if mimeType.caseInsensitiveCompare(MimeType.imageJpeg.rawValue) == .orderedSame {
            /// We can use a CGDataProvider. UIImage tends to load the whole thing into memory _anyway_,
            /// but this at least makes it possible for it to choose not to.
            return try CGDataProvider.loadFromEncryptedFile(
                at: fileURL,
                encryptionKey: encryptionKey,
                plaintextLength: plaintextLength
            ) { dataProvider in
                return UIImage(cgImage: try dataProvider.toJpegCGImage())
            }
        } else if mimeType.caseInsensitiveCompare(MimeType.imagePng.rawValue) == .orderedSame {
            /// We can use a CGDataProvider. UIImage tends to load the whole thing into memory _anyway_,
            /// but this at least makes it possible for it to choose not to.
            return try CGDataProvider.loadFromEncryptedFile(
                at: fileURL,
                encryptionKey: encryptionKey,
                plaintextLength: plaintextLength
            ) { dataProvider in
                return UIImage(cgImage: try dataProvider.toPngCGImage())
            }
        } else {
            Logger.warn("Loading non-jpeg, non-png image into memory")
            let data = try Cryptography.decryptFile(
                at: fileURL,
                metadata: .init(
                    key: encryptionKey,
                    plaintextLength: plaintextLength.map(Int.init(_:))
                )
            )
            let image: UIImage?
            if mimeType.caseInsensitiveCompare(MimeType.imageWebp.rawValue) == .orderedSame {
                /// Use YYImage for webp.
                image = YYImage(data: data)
            } else {
                image = UIImage(data: data)
            }

            guard let image else {
                throw OWSAssertionError("Failed to load image")
            }
            return image
        }
    }
}

extension CGDataProvider {

    // Class-bound wrapper around EncryptedFileHandle
    class EncryptedFileHandleWrapper {
        let fileHandle: SignalCoreKit.EncryptedFileHandle

        init(_ fileHandle: SignalCoreKit.EncryptedFileHandle) {
            self.fileHandle = fileHandle
        }
    }

    /// If no plaintext length is provided, the file is assumed to only use pkcs7 padding.
    fileprivate static func loadFromEncryptedFile<T>(
        at fileURL: URL,
        encryptionKey: Data,
        plaintextLength: UInt32?,
        block: (CGDataProvider) throws -> T
    ) throws -> T {
        let fileHandle: EncryptedFileHandle
        if let plaintextLength {
            fileHandle = try Cryptography.encryptedAttachmentFileHandle(
                at: fileURL,
                plaintextLength: plaintextLength,
                encryptionKey: encryptionKey
            )
        } else {
            fileHandle = try Cryptography.encryptedFileHandle(
                at: fileURL,
                encryptionKey: encryptionKey
            )
        }
        let dataProvider = try CGDataProvider.from(fileHandle: fileHandle)
        return try block(dataProvider)
    }

    public static func from(fileHandle: EncryptedFileHandle) throws -> CGDataProvider {
        let fileHandle = EncryptedFileHandleWrapper(fileHandle)

        var callbacks = CGDataProviderDirectCallbacks(
            version: 0,
            getBytePointer: nil,
            releaseBytePointer: nil,
            getBytesAtPosition: { info, buffer, offset, byteCount in
                guard
                    let unmanagedFileHandle = info?.assumingMemoryBound(
                        to: Unmanaged<EncryptedFileHandleWrapper>.self
                    ).pointee
                else {
                    return 0
                }
                let fileHandle = unmanagedFileHandle.takeUnretainedValue().fileHandle
                do {
                    if offset != fileHandle.offset() {
                        try fileHandle.seek(toOffset: UInt32(offset))
                    }
                    let data = try fileHandle.read(upToCount: UInt32(byteCount))
                    data.withUnsafeBytes { bytes in
                        buffer.copyMemory(from: bytes.baseAddress!, byteCount: bytes.count)
                    }
                    return data.count
                } catch {
                    return 0
                }
            },
            releaseInfo: { info in
                guard
                    let unmanagedFileHandle = info?.assumingMemoryBound(
                        to: Unmanaged<EncryptedFileHandleWrapper>.self
                    ).pointee
                else {
                    return
                }
                unmanagedFileHandle.release()
            }
        )

        var unmanagedFileHandle = Unmanaged.passRetained(fileHandle)

        guard let dataProvider = CGDataProvider(
            directInfo: &unmanagedFileHandle,
            size: Int64(fileHandle.fileHandle.plaintextLength),
            callbacks: &callbacks
        ) else {
            throw OWSAssertionError("Failed to create data provider")
        }
        return dataProvider
    }
}

extension CGDataProvider {

    fileprivate func toPngCGImage() throws -> CGImage {
        guard let cgImage = CGImage(
            pngDataProviderSource: self,
            decode: nil,
            shouldInterpolate: true,
            intent: .defaultIntent
        ) else {
            throw OWSAssertionError("Failed to create CGImage")
        }
        return cgImage
    }

    fileprivate func toJpegCGImage() throws -> CGImage {
        guard let cgImage = CGImage(
            jpegDataProviderSource: self,
            decode: nil,
            shouldInterpolate: true,
            intent: .defaultIntent
        ) else {
            throw OWSAssertionError("Failed to create CGImage")
        }
        return cgImage
    }
}

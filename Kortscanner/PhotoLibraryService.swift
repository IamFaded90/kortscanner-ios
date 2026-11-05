import Foundation
import Photos

@MainActor
enum PhotoLibraryService {
    static func save(_ images: [Data]) async throws {
        let authorization = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
        guard authorization == .authorized || authorization == .limited else {
            throw APIError.message("Giv adgang til Fotos for at gemme i albummet Kortscanner.")
        }
        let options = PHFetchOptions()
        options.predicate = NSPredicate(format: "title = %@", "Kortscanner")
        var album = PHAssetCollection.fetchAssetCollections(with: .album, subtype: .any, options: options).firstObject
        if album == nil {
            var identifier: String?
            try await PHPhotoLibrary.shared().performChanges {
                let request = PHAssetCollectionChangeRequest.creationRequestForAssetCollection(withTitle: "Kortscanner")
                identifier = request.placeholderForCreatedAssetCollection.localIdentifier
            }
            if let identifier { album = PHAssetCollection.fetchAssetCollections(withLocalIdentifiers: [identifier], options: nil).firstObject }
        }
        guard let album else { throw APIError.message("Fotoalbummet kunne ikke oprettes. Kontrollér adgangen til Fotos.") }
        try await PHPhotoLibrary.shared().performChanges {
            let placeholders: [PHObjectPlaceholder] = images.compactMap { data in
                let request = PHAssetCreationRequest.forAsset()
                let options = PHAssetResourceCreationOptions()
                options.uniformTypeIdentifier = "public.jpeg"
                request.addResource(with: .photo, data: data, options: options)
                return request.placeholderForCreatedAsset
            }
            PHAssetCollectionChangeRequest(for: album)?.addAssets(placeholders as NSArray)
        }
    }
}

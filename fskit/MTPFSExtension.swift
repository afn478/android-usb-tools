import ExtensionFoundation
import FSKit

@main
struct MTPFSExtension: UnaryFileSystemExtension {
    var fileSystem: FSUnaryFileSystem & FSUnaryFileSystemOperations {
        MTPFileSystem()
    }
}

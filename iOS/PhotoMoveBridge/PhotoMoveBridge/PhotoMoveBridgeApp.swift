import Combine
import CryptoKit
import Photos
import PhotosUI
import SwiftUI
import UIKit

@main
struct PhotoMoveBridgeApp: App {
    @StateObject private var appState = AppState()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(appState)
        }
    }
}

// MARK: - Models

enum TransferStatus: String, Codable, CaseIterable, Identifiable, Sendable {
    case pending
    case uploading
    case copied
    case verified
    case failed
    case deleteReady
    case deletedFromIPhone

    var id: String { rawValue }

    var title: String {
        switch self {
        case .pending: "대기"
        case .uploading: "전송 중"
        case .copied: "복사됨"
        case .verified: "검증 완료"
        case .failed: "실패"
        case .deleteReady: "삭제 가능"
        case .deletedFromIPhone: "이동 완료"
        }
    }

    var tint: Color {
        switch self {
        case .pending: .secondary
        case .uploading: .blue
        case .copied: .teal
        case .verified: .green
        case .failed: .red
        case .deleteReady: .orange
        case .deletedFromIPhone: .purple
        }
    }
}

enum BridgeMediaType: String, Codable, Sendable {
    case photo
    case video
    case unknown

    var headerValue: String {
        switch self {
        case .photo: "photo"
        case .video: "video"
        case .unknown: "unknown"
        }
    }

    var iconName: String {
        switch self {
        case .photo: "photo"
        case .video: "video"
        case .unknown: "questionmark.square"
        }
    }
}

struct PhotoAssetItem: Identifiable, Codable, Equatable, Sendable {
    var id: String { resourceIdentifier }

    let assetLocalIdentifier: String
    let resourceIdentifier: String
    let resourceIndex: Int
    let resourceTypeRawValue: Int
    let originalFilename: String
    let creationDate: Date?
    let mediaType: BridgeMediaType
    let uniformTypeIdentifier: String?
    var fileSize: Int64
    var sha256: String?
    var transferStatus: TransferStatus
    var remoteSavedPath: String?
    var targetDriveLetter: String?
    var targetVolumeLabel: String?
    var errorCode: String?
    var errorMessage: String?
    var isSelected: Bool
}

struct TransferSession: Identifiable, Codable {
    var id: UUID
    var startedAt: Date
    var completedAt: Date?
    var windowsHost: String
    var windowsPort: Int
    var targetRoot: String?
    var targetDriveLetter: String?
    var targetVolumeLabel: String?
    var totalCount: Int
    var successCount: Int
    var failedCount: Int
    var deleteReadyCount: Int
    var deletedCount: Int
}

struct TransferLog: Identifiable, Codable {
    var id: UUID
    var sessionId: UUID?
    var assetId: String
    var resourceId: String
    var originalFilename: String
    var status: TransferStatus
    var localFileSize: Int64?
    var remoteFileSize: Int64?
    var localSha256: String?
    var remoteSha256: String?
    var savedPath: String?
    var errorCode: String?
    var errorMessage: String?
    var timestamp: Date
}

struct UsbExportManifest: Codable {
    var appName: String
    var exportVersion: String
    var sessionId: String
    var createdAt: Date
    var fileCount: Int
    var totalBytes: Int64
    var files: [UsbExportFile]
}

struct UsbExportFile: Codable {
    var assetId: String
    var resourceId: String
    var originalFilename: String
    var relativePath: String
    var createdAt: Date?
    var mediaType: String
    var fileSize: Int64
    var sha256: String
}

struct MonthGroup: Identifiable, Sendable {
    var id: String
    var title: String
    var selectedCount: Int
    var items: [PhotoAssetItem]
    var days: [DayGroup]

    var isFullySelected: Bool {
        !items.isEmpty && selectedCount == items.count
    }
}

struct DayGroup: Identifiable, Sendable {
    var id: String
    var title: String
    var selectedCount: Int
    var items: [PhotoAssetItem]

    var isFullySelected: Bool {
        !items.isEmpty && selectedCount == items.count
    }
}

struct PhotoLibraryLoadBatch: Sendable {
    var items: [PhotoAssetItem]
    var scannedAssetCount: Int
    var totalAssetCount: Int
    var isComplete: Bool
}

// MARK: - App State

@MainActor
final class AppState: ObservableObject {
    @Published var permissionStatus: PHAuthorizationStatus = PHPhotoLibrary.authorizationStatus(for: .readWrite)
    @Published var assets: [PhotoAssetItem]
    @Published var monthGroups: [MonthGroup] = []
    @Published var logs: [TransferLog] = LogStore.load()
    @Published var isLoadingPhotos = false
    @Published var isPreparingPhotoGroups = false
    @Published var photoLoadScannedCount = 0
    @Published var photoLoadTotalCount = 0
    @Published var selectedCount = 0
    @Published var selectedTotalSize: Int64 = 0
    @Published var transferIsRunning = false
    @Published var currentFileName = ""
    @Published var currentFileProgress = 0.0
    @Published var overallProgress = 0.0
    @Published var successCount = 0
    @Published var failedCount = 0
    @Published var pendingCount = 0
    @Published var retryCount = 0
    @Published var transferSpeedText = "-"
    @Published var estimatedRemainingText = "-"
    @Published var deleteConfirmationChecked = false
    @Published var lastErrorMessage: String?
    @Published var usbExportMessage = "USB 내보내기를 만들면 Windows에서 해당 폴더를 선택해 PC 하드나 외장하드로 가져올 수 있습니다."
    @Published var usbExportFolderName = ""
    @Published var usbExportPathText = ""

    private let photoService = PhotoLibraryService()
    private var activeSession: TransferSession?
    private var transferStartedAt: Date?
    private var plannedTransferBytes: Int64 = 0
    private var photoLoadGeneration = UUID()
    private var photoGroupingGeneration = UUID()
    private var assetIndexById: [String: Int] = [:]
    private var hasBootstrappedPhotoLibrary = false

    init() {
        let cachedAssets = PhotoAssetCache.load()
        assets = cachedAssets
        pendingCount = cachedAssets.count
        rebuildAssetIndex()
        refreshSelectionSummary()
    }

    var isPhotoAccessGranted: Bool {
        permissionStatus == .authorized || permissionStatus == .limited
    }

    var permissionTitle: String {
        switch permissionStatus {
        case .authorized: "전체 사진 접근 허용됨"
        case .limited: "제한된 사진 접근 허용됨"
        case .denied: "사진 접근 거부됨"
        case .restricted: "사진 접근 제한됨"
        case .notDetermined: "사진 접근 권한 필요"
        @unknown default: "사진 접근 상태 확인 필요"
        }
    }

    var selectedItems: [PhotoAssetItem] {
        assets.filter(\.isSelected)
    }

    var photoLoadProgressFraction: Double? {
        guard photoLoadTotalCount > 0 else { return nil }
        return min(Double(photoLoadScannedCount) / Double(photoLoadTotalCount), 1)
    }

    var photoLoadProgressText: String {
        if photoLoadTotalCount > 0 {
            return "\(photoLoadScannedCount)/\(photoLoadTotalCount)개 보관함 항목 스캔, \(assets.count)개 파일 발견"
        }
        return "\(assets.count)개 파일 발견"
    }

    var deleteReadyItems: [PhotoAssetItem] {
        assets.filter { $0.transferStatus == .deleteReady }
    }

    var verificationPendingItems: [PhotoAssetItem] {
        assets.filter { $0.transferStatus == .copied }
    }

    var failedItems: [PhotoAssetItem] {
        assets.filter { $0.transferStatus == .failed }
    }

    var successfulItems: [PhotoAssetItem] {
        assets.filter { $0.transferStatus == .copied || $0.transferStatus == .verified || $0.transferStatus == .deleteReady || $0.transferStatus == .deletedFromIPhone }
    }

    var canPrepareUsbExport: Bool {
        selectedCount > 0 && !transferIsRunning && !isLoadingPhotos
    }

    var deleteButtonAvailable: Bool {
        !deleteReadyItems.isEmpty && failedItems.isEmpty && !transferIsRunning
    }

    func refreshPermissionStatus() {
        permissionStatus = PHPhotoLibrary.authorizationStatus(for: .readWrite)
    }

    func bootstrapPhotoLibrary() async {
        refreshPermissionStatus()
        guard !hasBootstrappedPhotoLibrary else { return }
        hasBootstrappedPhotoLibrary = true

        if !assets.isEmpty {
            await rebuildMonthGroups()
            return
        }

        if isPhotoAccessGranted {
            await loadPhotos()
        }
    }

    func requestPhotoPermission() async {
        permissionStatus = await photoService.requestAuthorization()
        if isPhotoAccessGranted {
            await loadPhotos()
        }
    }

    func presentLimitedPicker() {
        guard let viewController = UIApplication.shared.activeRootViewController else { return }
        PHPhotoLibrary.shared().presentLimitedLibraryPicker(from: viewController)
    }

    func loadPhotos() async {
        guard isPhotoAccessGranted else { return }
        let generation = UUID()
        photoLoadGeneration = generation
        isLoadingPhotos = true
        lastErrorMessage = nil
        photoLoadScannedCount = 0
        photoLoadTotalCount = 0
        assets = []
        monthGroups = []
        selectedCount = 0
        selectedTotalSize = 0
        assetIndexById = [:]
        pendingCount = 0
        do {
            for try await batch in photoService.fetchTransferableResourceBatches(batchSize: 250) {
                guard generation == photoLoadGeneration else { throw CancellationError() }
                photoLoadScannedCount = batch.scannedAssetCount
                photoLoadTotalCount = batch.totalAssetCount
                if !batch.items.isEmpty {
                    assets.append(contentsOf: batch.items)
                    pendingCount = assets.count
                }
                if batch.isComplete { break }
            }
            rebuildAssetIndex()
            refreshSelectionSummary()
            savePhotoCacheSnapshot()
            await rebuildMonthGroups()
        } catch {
            if !(error is CancellationError) {
                lastErrorMessage = error.localizedDescription
            }
        }
        if generation == photoLoadGeneration {
            isLoadingPhotos = false
        }
    }

    func toggleSelection(_ item: PhotoAssetItem) {
        guard let index = assetIndexById[item.id] else { return }
        var updated = assets
        let wasSelected = updated[index].isSelected
        updated[index].isSelected.toggle()
        applySelectionDelta(item: updated[index], wasSelected: wasSelected, isSelected: updated[index].isSelected)
        assets = updated
        scheduleMonthGroupRebuild()
        savePhotoCacheSnapshot()
    }

    func setSelection(for ids: [String], selected: Bool) {
        var updated = assets
        var deltaCount = 0
        var deltaSize: Int64 = 0

        for id in ids {
            guard let index = assetIndexById[id], updated[index].isSelected != selected else { continue }
            updated[index].isSelected = selected
            deltaCount += selected ? 1 : -1
            deltaSize += selected ? updated[index].fileSize : -updated[index].fileSize
        }

        guard deltaCount != 0 || deltaSize != 0 else { return }
        selectedCount = max(selectedCount + deltaCount, 0)
        selectedTotalSize = max(selectedTotalSize + deltaSize, 0)
        assets = updated
        scheduleMonthGroupRebuild()
        savePhotoCacheSnapshot()
    }

    func toggleMonth(_ month: MonthGroup) {
        setSelection(for: month.items.map(\.id), selected: !month.isFullySelected)
    }

    func toggleDay(_ day: DayGroup) {
        setSelection(for: day.items.map(\.id), selected: !day.isFullySelected)
    }

    func clearSelection() {
        guard selectedCount > 0 else { return }
        var updated = assets
        for index in updated.indices {
            updated[index].isSelected = false
        }
        assets = updated
        selectedCount = 0
        selectedTotalSize = 0
        scheduleMonthGroupRebuild()
        savePhotoCacheSnapshot()
    }

    func selectAll() {
        guard selectedCount != assets.count else { return }
        var updated = assets
        var totalSize: Int64 = 0
        for index in updated.indices {
            updated[index].isSelected = true
            totalSize += updated[index].fileSize
        }
        assets = updated
        selectedCount = updated.count
        selectedTotalSize = totalSize
        scheduleMonthGroupRebuild()
        savePhotoCacheSnapshot()
    }

    func retryFailedTransfers() async {
        await prepareUsbExport(retryFailedOnly: true)
    }

    /// 사용자가 Windows 앱에서 가져오기·SHA256 검증을 끝냈다고 확인하면,
    /// 복사 완료(`.copied`) 항목을 검증 완료(`.verified`)로 표시하고
    /// 자산 단위로 모든 리소스가 검증된 항목만 삭제 가능(`.deleteReady`)으로 승격합니다.
    func confirmWindowsVerification() {
        guard !transferIsRunning else { return }
        var changed = false
        for index in assets.indices where assets[index].transferStatus == .copied {
            assets[index].transferStatus = .verified
            appendLog(
                item: assets[index],
                status: .verified,
                localFileSize: assets[index].fileSize,
                remoteFileSize: assets[index].fileSize,
                localSha256: assets[index].sha256,
                remoteSha256: assets[index].sha256,
                savedPath: assets[index].remoteSavedPath,
                errorCode: nil,
                errorMessage: nil
            )
            changed = true
        }
        guard changed else { return }
        refreshDeleteReadyStates()
        activeSession?.deleteReadyCount = deleteReadyItems.count
        scheduleMonthGroupRebuild()
        savePhotoCacheSnapshot()
        LogStore.save(logs)
    }

    func prepareUsbExport(retryFailedOnly: Bool = false) async {
        guard !transferIsRunning else { return }
        let candidates = usbExportCandidates(retryFailedOnly: retryFailedOnly)
        guard !candidates.isEmpty else {
            lastErrorMessage = "USB로 내보낼 선택 항목이 없습니다."
            return
        }

        transferIsRunning = true
        transferStartedAt = Date()
        plannedTransferBytes = max(candidates.reduce(0) { $0 + max($1.fileSize, 0) }, 1)
        overallProgress = 0
        currentFileProgress = 0
        successCount = 0
        failedCount = 0
        retryCount = retryFailedOnly ? candidates.count : 0
        pendingCount = candidates.count
        transferSpeedText = "-"
        estimatedRemainingText = "-"
        lastErrorMessage = nil

        let sessionId = "PhotoMoveBridge-" + Formatters.exportSession.string(from: Date())
        usbExportFolderName = sessionId
        usbExportPathText = "PhotoMoveBridgeUSBExport/\(sessionId)"
        usbExportMessage = "USB 내보내기 폴더를 준비하는 중입니다."

        let session = TransferSession(
            id: UUID(),
            startedAt: Date(),
            completedAt: nil,
            windowsHost: "USB",
            windowsPort: 0,
            targetRoot: usbExportPathText,
            targetDriveLetter: nil,
            targetVolumeLabel: nil,
            totalCount: candidates.count,
            successCount: 0,
            failedCount: 0,
            deleteReadyCount: 0,
            deletedCount: 0
        )
        activeSession = session

        var manifestFiles: [UsbExportFile] = []
        var usedRelativePaths = Set<String>()
        var completedBytes: Int64 = 0

        do {
            let exportRootURL = try FileUtilities.usbExportRootDirectory()
            let sessionURL = exportRootURL.appendingPathComponent(sessionId, isDirectory: true)
            try FileManager.default.createDirectory(at: sessionURL, withIntermediateDirectories: true)
            try FileUtilities.excludeFromBackup(sessionURL)

            for (offset, originalItem) in candidates.enumerated() {
                guard var item = assets.first(where: { $0.id == originalItem.id }) else { continue }
                updateItem(item.id) {
                    $0.transferStatus = .uploading
                    $0.errorCode = nil
                    $0.errorMessage = nil
                }
                currentFileName = item.originalFilename
                currentFileProgress = 0

                do {
                    let exportedURL = try await photoService.exportOriginalResource(for: item)
                    defer { try? FileManager.default.removeItem(at: exportedURL) }

                    let localSize = try FileUtilities.fileSize(at: exportedURL)
                    currentFileProgress = 0.35
                    let localHash = try await Task.detached(priority: .userInitiated) {
                        try FileUtilities.sha256HexDigest(for: exportedURL)
                    }.value
                    currentFileProgress = 0.65

                    let relativePath = FileUtilities.usbRelativePath(for: item, usedPaths: &usedRelativePaths)
                    let destinationURL = sessionURL.appendingRelativePath(relativePath)
                    try await Task.detached(priority: .userInitiated) {
                        try FileUtilities.copyFileReplacingExisting(from: exportedURL, to: destinationURL)
                    }.value
                    try FileUtilities.excludeFromBackup(destinationURL)

                    let savedPath = "\(usbExportPathText)/\(relativePath)"
                    item.fileSize = localSize
                    item.sha256 = localHash
                    updateItem(item.id) {
                        $0.fileSize = localSize
                        $0.sha256 = localHash
                        $0.transferStatus = .copied
                        $0.remoteSavedPath = savedPath
                        $0.errorCode = nil
                        $0.errorMessage = nil
                    }

                    manifestFiles.append(
                        UsbExportFile(
                            assetId: item.assetLocalIdentifier,
                            resourceId: item.resourceIdentifier,
                            originalFilename: item.originalFilename,
                            relativePath: relativePath,
                            createdAt: item.creationDate,
                            mediaType: item.mediaType.rawValue,
                            fileSize: localSize,
                            sha256: localHash
                        )
                    )
                    successCount += 1
                    appendLog(
                        item: item,
                        status: .copied,
                        localFileSize: localSize,
                        remoteFileSize: localSize,
                        localSha256: localHash,
                        remoteSha256: localHash,
                        savedPath: savedPath,
                        errorCode: nil,
                        errorMessage: nil
                    )
                    completedBytes += max(localSize, 0)
                    currentFileProgress = 1
                    updateSpeedAndETA(completedBytes: completedBytes, expectedCurrentFileBytes: 0)
                } catch {
                    markFailed(
                        item: item,
                        localFileSize: item.fileSize,
                        localSha256: item.sha256,
                        remoteFileSize: nil,
                        remoteSha256: nil,
                        savedPath: nil,
                        errorCode: "USB_EXPORT_ERROR",
                        errorMessage: error.localizedDescription
                    )
                }

                pendingCount = max(candidates.count - offset - 1, 0)
                overallProgress = Double(offset + 1) / Double(max(candidates.count, 1))
            }

            if !manifestFiles.isEmpty {
                let manifest = UsbExportManifest(
                    appName: "PhotoMove Bridge",
                    exportVersion: "1.0",
                    sessionId: sessionId,
                    createdAt: Date(),
                    fileCount: manifestFiles.count,
                    totalBytes: manifestFiles.reduce(0) { $0 + $1.fileSize },
                    files: manifestFiles
                )
                let manifestData = try JSONEncoder.bridgeEncoder.encode(manifest)
                let manifestURL = sessionURL.appendingPathComponent("manifest.json")
                try manifestData.write(to: manifestURL, options: [.atomic])
                try FileUtilities.excludeFromBackup(manifestURL)
            }

            usbExportMessage = manifestFiles.isEmpty
                ? "USB 내보내기에 성공한 파일이 없습니다. 실패 항목을 확인하세요."
                : "USB 내보내기 완료: USB 케이블로 Windows에 연결한 뒤 Apple Devices/iTunes 파일 공유에서 \(usbExportPathText) 세션 폴더를 Windows 앱으로 가져오세요."
        } catch {
            lastErrorMessage = "USB 내보내기 준비 실패: \(error.localizedDescription)"
            usbExportMessage = lastErrorMessage ?? "USB 내보내기 준비 실패"
        }

        activeSession?.completedAt = Date()
        activeSession?.successCount = successCount
        activeSession?.failedCount = failedCount
        transferIsRunning = false
        currentFileProgress = 0
        currentFileName = ""
        savePhotoCacheSnapshot()
        LogStore.save(logs)
    }

    func deleteReadyAssetsFromIPhone() async {
        guard deleteConfirmationChecked, deleteButtonAvailable else { return }
        let identifiers = Array(Set(deleteReadyItems.map(\.assetLocalIdentifier)))
        guard !identifiers.isEmpty else { return }

        do {
            try await photoService.deleteAssets(withLocalIdentifiers: identifiers)
            for id in identifiers {
                for index in assets.indices where assets[index].assetLocalIdentifier == id {
                    assets[index].transferStatus = .deletedFromIPhone
                    assets[index].isSelected = false
                    appendLog(
                        item: assets[index],
                        status: .deletedFromIPhone,
                        localFileSize: assets[index].fileSize,
                        remoteFileSize: assets[index].fileSize,
                        localSha256: assets[index].sha256,
                        remoteSha256: assets[index].sha256,
                        savedPath: assets[index].remoteSavedPath,
                        errorCode: nil,
                        errorMessage: nil
                    )
                }
            }
            activeSession?.deletedCount += identifiers.count
            deleteConfirmationChecked = false
        } catch {
            for item in deleteReadyItems {
                appendLog(
                    item: item,
                    status: .failed,
                    localFileSize: item.fileSize,
                    remoteFileSize: item.fileSize,
                    localSha256: item.sha256,
                    remoteSha256: item.sha256,
                    savedPath: item.remoteSavedPath,
                    errorCode: "PHOTOKIT_DELETE_FAILED",
                    errorMessage: error.localizedDescription
                )
            }
            lastErrorMessage = "iPhone 사진 보관함 삭제 실패: \(error.localizedDescription)"
        }
        LogStore.save(logs)
    }

    func clearLogs() {
        logs.removeAll()
        LogStore.save(logs)
    }

    private func rebuildAssetIndex() {
        assetIndexById = Dictionary(uniqueKeysWithValues: assets.enumerated().map { index, item in
            (item.id, index)
        })
    }

    private func refreshSelectionSummary() {
        selectedCount = 0
        selectedTotalSize = 0
        for item in assets where item.isSelected {
            selectedCount += 1
            selectedTotalSize += item.fileSize
        }
    }

    private func applySelectionDelta(item: PhotoAssetItem, wasSelected: Bool, isSelected: Bool) {
        guard wasSelected != isSelected else { return }
        selectedCount = max(selectedCount + (isSelected ? 1 : -1), 0)
        selectedTotalSize = max(selectedTotalSize + (isSelected ? item.fileSize : -item.fileSize), 0)
    }

    private func rebuildMonthGroups() async {
        let generation = UUID()
        photoGroupingGeneration = generation
        isPreparingPhotoGroups = true
        let snapshot = assets
        let groups = await Task.detached(priority: .userInitiated) {
            PhotoGrouping.makeMonthGroups(from: snapshot)
        }.value
        guard generation == photoGroupingGeneration else { return }
        monthGroups = groups
        isPreparingPhotoGroups = false
    }

    private func scheduleMonthGroupRebuild() {
        Task { await rebuildMonthGroups() }
    }

    private func savePhotoCacheSnapshot() {
        let snapshot = assets
        Task.detached(priority: .utility) {
            PhotoAssetCache.save(snapshot)
        }
    }

    private func usbExportCandidates(retryFailedOnly: Bool) -> [PhotoAssetItem] {
        if retryFailedOnly {
            return assets.filter { $0.isSelected && $0.transferStatus == .failed }
        }

        return selectedItems.filter {
            $0.transferStatus != .deletedFromIPhone && $0.transferStatus != .uploading
        }
    }

    private func updateItem(_ id: String, mutate: (inout PhotoAssetItem) -> Void) {
        guard let index = assets.firstIndex(where: { $0.id == id }) else { return }
        mutate(&assets[index])
    }

    private func refreshDeleteReadyStates() {
        let grouped = Dictionary(grouping: assets, by: \.assetLocalIdentifier)
        for (_, group) in grouped {
            let isComplete = group.allSatisfy {
                $0.transferStatus == .verified || $0.transferStatus == .deleteReady || $0.transferStatus == .deletedFromIPhone
            }
            guard isComplete else { continue }
            for item in group where item.transferStatus == .verified {
                updateItem(item.id) { $0.transferStatus = .deleteReady }
            }
        }
    }

    private func markFailed(
        item: PhotoAssetItem,
        localFileSize: Int64?,
        localSha256: String?,
        remoteFileSize: Int64?,
        remoteSha256: String?,
        savedPath: String?,
        errorCode: String,
        errorMessage: String
    ) {
        updateItem(item.id) {
            $0.transferStatus = .failed
            $0.errorCode = errorCode
            $0.errorMessage = errorMessage
            $0.remoteSavedPath = savedPath
        }
        failedCount += 1
        appendLog(
            item: item,
            status: .failed,
            localFileSize: localFileSize,
            remoteFileSize: remoteFileSize,
            localSha256: localSha256,
            remoteSha256: remoteSha256,
            savedPath: savedPath,
            errorCode: errorCode,
            errorMessage: errorMessage
        )
    }

    private func appendLog(
        item: PhotoAssetItem,
        status: TransferStatus,
        localFileSize: Int64?,
        remoteFileSize: Int64?,
        localSha256: String?,
        remoteSha256: String?,
        savedPath: String?,
        errorCode: String?,
        errorMessage: String?
    ) {
        logs.insert(
            TransferLog(
                id: UUID(),
                sessionId: activeSession?.id,
                assetId: item.assetLocalIdentifier,
                resourceId: item.resourceIdentifier,
                originalFilename: item.originalFilename,
                status: status,
                localFileSize: localFileSize,
                remoteFileSize: remoteFileSize,
                localSha256: localSha256,
                remoteSha256: remoteSha256,
                savedPath: savedPath,
                errorCode: errorCode,
                errorMessage: errorMessage,
                timestamp: Date()
            ),
            at: 0
        )
    }

    private func updateSpeedAndETA(completedBytes: Int64, expectedCurrentFileBytes: Int64) {
        guard let started = transferStartedAt else { return }
        let elapsed = max(Date().timeIntervalSince(started), 0.1)
        let bytesPerSecond = Double(completedBytes) / elapsed
        transferSpeedText = Formatters.bytes(Int64(bytesPerSecond)) + "/s"
        let total = max(plannedTransferBytes, completedBytes + max(expectedCurrentFileBytes, 0))
        let remaining = max(Double(total - completedBytes), 0)
        if bytesPerSecond > 0 {
            estimatedRemainingText = Formatters.duration(remaining / bytesPerSecond)
        }
    }
}

// MARK: - Photo Library

struct PhotoLibraryService {
    func requestAuthorization() async -> PHAuthorizationStatus {
        await withCheckedContinuation { continuation in
            PHPhotoLibrary.requestAuthorization(for: .readWrite) { status in
                continuation.resume(returning: status)
            }
        }
    }

    func fetchTransferableResources() async throws -> [PhotoAssetItem] {
        var items: [PhotoAssetItem] = []
        for try await batch in fetchTransferableResourceBatches(batchSize: 500) {
            items.append(contentsOf: batch.items)
        }
        return items.sortedForDisplay()
    }

    func fetchTransferableResourceBatches(batchSize: Int) -> AsyncThrowingStream<PhotoLibraryLoadBatch, Error> {
        AsyncThrowingStream { continuation in
            let task = Task.detached(priority: .userInitiated) {
                do {
                    try Self.validatePhotoAccess()

                    let options = PHFetchOptions()
                    options.predicate = NSPredicate(
                        format: "mediaType == %d OR mediaType == %d",
                        PHAssetMediaType.image.rawValue,
                        PHAssetMediaType.video.rawValue
                    )
                    options.sortDescriptors = [
                        NSSortDescriptor(key: "creationDate", ascending: false),
                        NSSortDescriptor(key: "modificationDate", ascending: false)
                    ]

                    let fetchResult = PHAsset.fetchAssets(with: options)
                    let totalAssetCount = fetchResult.count
                    var scannedAssetCount = 0
                    var batch: [PhotoAssetItem] = []

                    fetchResult.enumerateObjects { asset, _, stop in
                        if Task.isCancelled {
                            stop.pointee = true
                            return
                        }

                        scannedAssetCount += 1
                        autoreleasepool {
                            batch.append(contentsOf: Self.transferableItems(for: asset))
                        }

                        if batch.count >= batchSize || scannedAssetCount % 200 == 0 {
                            continuation.yield(
                                PhotoLibraryLoadBatch(
                                    items: batch,
                                    scannedAssetCount: scannedAssetCount,
                                    totalAssetCount: totalAssetCount,
                                    isComplete: false
                                )
                            )
                            batch.removeAll(keepingCapacity: true)
                        }
                    }

                    if Task.isCancelled {
                        continuation.finish(throwing: CancellationError())
                        return
                    }

                    if !batch.isEmpty {
                        continuation.yield(
                            PhotoLibraryLoadBatch(
                                items: batch,
                                scannedAssetCount: scannedAssetCount,
                                totalAssetCount: totalAssetCount,
                                isComplete: false
                            )
                        )
                    }

                    continuation.yield(
                        PhotoLibraryLoadBatch(
                            items: [],
                            scannedAssetCount: scannedAssetCount,
                            totalAssetCount: totalAssetCount,
                            isComplete: true
                        )
                    )
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }

            continuation.onTermination = { _ in
                task.cancel()
            }
        }
    }

    private static func validatePhotoAccess() throws {
        let status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        guard status == .authorized || status == .limited else {
            throw BridgeError.photoPermissionRequired
        }
    }

    private static func transferableItems(for asset: PHAsset) -> [PhotoAssetItem] {
        PHAssetResource.assetResources(for: asset)
            .enumerated()
            .compactMap { resourceIndex, resource in
                guard Self.isTransferable(resource) else { return nil }
                let mediaType = Self.mediaType(for: asset, resource: resource)
                let filename = resource.originalFilename
                let resourceId = [
                    asset.localIdentifier,
                    String(resourceIndex),
                    String(resource.type.rawValue),
                    filename
                ].joined(separator: "::")
                return PhotoAssetItem(
                    assetLocalIdentifier: asset.localIdentifier,
                    resourceIdentifier: resourceId,
                    resourceIndex: resourceIndex,
                    resourceTypeRawValue: resource.type.rawValue,
                    originalFilename: filename,
                    creationDate: asset.creationDate,
                    mediaType: mediaType,
                    uniformTypeIdentifier: resource.uniformTypeIdentifier,
                    fileSize: Self.bestEffortFileSize(resource),
                    sha256: nil,
                    transferStatus: .pending,
                    remoteSavedPath: nil,
                    targetDriveLetter: nil,
                    targetVolumeLabel: nil,
                    errorCode: nil,
                    errorMessage: nil,
                    isSelected: false
                )
            }
    }

    func thumbnail(for localIdentifier: String, targetSize: CGSize) async -> UIImage? {
        guard let asset = fetchAsset(localIdentifier: localIdentifier) else { return nil }
        return await withCheckedContinuation { continuation in
            let options = PHImageRequestOptions()
            options.deliveryMode = .opportunistic
            options.resizeMode = .fast
            options.isNetworkAccessAllowed = true

            var didResume = false
            PHImageManager.default().requestImage(
                for: asset,
                targetSize: targetSize,
                contentMode: .aspectFill,
                options: options
            ) { image, info in
                let degraded = (info?[PHImageResultIsDegradedKey] as? Bool) ?? false
                guard !didResume, image != nil, !degraded else { return }
                didResume = true
                continuation.resume(returning: image)
            }
        }
    }

    func exportOriginalResource(for item: PhotoAssetItem) async throws -> URL {
        guard let resource = matchingResource(for: item) else {
            throw BridgeError.assetResourceNotFound
        }

        let safeName = FileUtilities.safeTemporaryFilename(item.originalFilename)
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension(safeName)
        try? FileManager.default.removeItem(at: fileURL)

        let options = PHAssetResourceRequestOptions()
        options.isNetworkAccessAllowed = true

        return try await withCheckedThrowingContinuation { continuation in
            PHAssetResourceManager.default().writeData(for: resource, toFile: fileURL, options: options) { error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: fileURL)
                }
            }
        }
    }

    func deleteAssets(withLocalIdentifiers identifiers: [String]) async throws {
        let fetchResult = PHAsset.fetchAssets(withLocalIdentifiers: identifiers, options: nil)
        var assetsToDelete: [PHAsset] = []
        fetchResult.enumerateObjects { asset, _, _ in
            assetsToDelete.append(asset)
        }
        guard !assetsToDelete.isEmpty else { return }

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            PHPhotoLibrary.shared().performChanges {
                PHAssetChangeRequest.deleteAssets(assetsToDelete as NSArray)
            } completionHandler: { success, error in
                if let error {
                    continuation.resume(throwing: error)
                } else if success {
                    continuation.resume()
                } else {
                    continuation.resume(throwing: BridgeError.photoKitDeleteFailed)
                }
            }
        }
    }

    private func fetchAsset(localIdentifier: String) -> PHAsset? {
        PHAsset.fetchAssets(withLocalIdentifiers: [localIdentifier], options: nil).firstObject
    }

    private func matchingResource(for item: PhotoAssetItem) -> PHAssetResource? {
        guard let asset = fetchAsset(localIdentifier: item.assetLocalIdentifier) else { return nil }
        let resources = PHAssetResource.assetResources(for: asset)
        if item.resourceIndex < resources.count {
            let resource = resources[item.resourceIndex]
            if resource.originalFilename == item.originalFilename && resource.type.rawValue == item.resourceTypeRawValue {
                return resource
            }
        }
        return resources.first {
            $0.originalFilename == item.originalFilename && $0.type.rawValue == item.resourceTypeRawValue
        }
    }

    private static func isTransferable(_ resource: PHAssetResource) -> Bool {
        switch resource.type {
        case .photo, .video, .fullSizePhoto, .fullSizeVideo, .pairedVideo, .fullSizePairedVideo, .photoProxy:
            return true
        default:
            return false
        }
    }

    private static func mediaType(for asset: PHAsset, resource: PHAssetResource) -> BridgeMediaType {
        switch resource.type {
        case .video, .fullSizeVideo, .pairedVideo, .fullSizePairedVideo:
            return .video
        case .photo, .fullSizePhoto, .photoProxy:
            return .photo
        default:
            switch asset.mediaType {
            case .image: return .photo
            case .video: return .video
            default: return .unknown
            }
        }
    }

    private static func bestEffortFileSize(_ resource: PHAssetResource) -> Int64 {
        _ = resource
        return 0
    }
}

// MARK: - Views

struct ContentView: View {
    @EnvironmentObject private var appState: AppState

    var body: some View {
        TabView {
            NavigationStack {
                PermissionScreen()
            }
            .tabItem { Label("권한", systemImage: "lock.shield") }

            NavigationStack {
                UsbConnectionScreen()
            }
            .tabItem { Label("USB", systemImage: "externaldrive") }

            NavigationStack {
                PhotoSelectionScreen()
            }
            .tabItem { Label("사진", systemImage: "photo.on.rectangle") }

            NavigationStack {
                MovePreparationScreen()
            }
            .tabItem { Label("이동", systemImage: "externaldrive.badge.arrowtriangle.2.circlepath") }

            NavigationStack {
                LogScreen()
            }
            .tabItem { Label("로그", systemImage: "doc.text.magnifyingglass") }
        }
        .task {
            await appState.bootstrapPhotoLibrary()
        }
    }
}

struct PermissionScreen: View {
    @EnvironmentObject private var appState: AppState

    var body: some View {
        List {
            Section {
                Label(appState.permissionTitle, systemImage: appState.isPhotoAccessGranted ? "checkmark.seal.fill" : "photo.badge.exclamationmark")
                    .foregroundStyle(appState.isPhotoAccessGranted ? .green : .orange)

                Text("제한된 접근 권한에서는 사용자가 허용한 사진과 동영상만 표시됩니다.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section {
                Button {
                    Task { await appState.requestPhotoPermission() }
                } label: {
                    Label("사진 접근 권한 요청", systemImage: "person.crop.rectangle.stack")
                }

                if appState.permissionStatus == .limited {
                    Button {
                        appState.presentLimitedPicker()
                    } label: {
                        Label("제한된 사진 선택 수정", systemImage: "slider.horizontal.3")
                    }
                }

                Button {
                    Task { await appState.loadPhotos() }
                } label: {
                    Label("사진/동영상 다시 불러오기", systemImage: "arrow.clockwise")
                }
                .disabled(!appState.isPhotoAccessGranted || appState.isLoadingPhotos)
            }

            if let message = appState.lastErrorMessage {
                Section {
                    Text(message)
                        .foregroundStyle(.red)
                }
            }
        }
        .navigationTitle("권한")
    }
}

struct UsbConnectionScreen: View {
    @EnvironmentObject private var appState: AppState

    var body: some View {
        List {
            Section("USB 이동 방식") {
                Label("별도 Wi-Fi 없이 USB 케이블로 Windows 컴퓨터에 연결합니다.", systemImage: "cable.connector")
                Text("이 앱은 선택한 원본 사진/동영상을 앱 문서 폴더의 USB 내보내기 패키지로 만듭니다.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                Text("Windows의 Apple Devices 또는 iTunes 파일 공유에서 PhotoMoveBridgeUSBExport 세션 폴더를 선택한 뒤 Windows 앱에서 PC 하드나 외장하드로 가져옵니다.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section("최근 USB 내보내기") {
                LabeledContent("폴더") {
                    Text(appState.usbExportPathText.isEmpty ? "아직 없음" : appState.usbExportPathText)
                        .multilineTextAlignment(.trailing)
                        .textSelection(.enabled)
                }
                Text(appState.usbExportMessage)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section("Windows에서 선택할 항목") {
                Label("iPhone 앱 문서: PhotoMoveBridgeUSBExport", systemImage: "folder")
                Label("내보내기 세션: PhotoMoveBridge-날짜시간 폴더", systemImage: "folder.badge.gearshape")
                Label("저장 대상: 컴퓨터 하드 또는 외장하드의 원하는 폴더", systemImage: "internaldrive")
            }
        }
        .navigationTitle("USB 연결")
    }
}

struct PhotoSelectionScreen: View {
    @EnvironmentObject private var appState: AppState

    private let columns = [
        GridItem(.adaptive(minimum: 92, maximum: 130), spacing: 10)
    ]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                selectionSummary

                if appState.isLoadingPhotos {
                    photoLoadingStatus
                }

                if appState.isPreparingPhotoGroups, appState.monthGroups.isEmpty, !appState.assets.isEmpty {
                    ProgressView("월별 목록 정리 중")
                        .frame(maxWidth: .infinity)
                        .padding()
                        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 8))
                } else if appState.assets.isEmpty && !appState.isLoadingPhotos {
                    ContentUnavailableView(
                        "표시할 항목이 없습니다",
                        systemImage: "photo.stack",
                        description: Text("권한을 허용한 뒤 사진/동영상을 다시 불러오세요.")
                    )
                    .padding(.top, 80)
                } else {
                    ForEach(appState.monthGroups) { month in
                        monthSection(month)
                    }
                }
            }
            .padding()
        }
        .navigationTitle("사진 선택")
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                Button {
                    appState.clearSelection()
                } label: {
                    Image(systemName: "xmark.circle")
                }
                .accessibilityLabel("전체 선택 해제")
                .disabled(appState.isLoadingPhotos || appState.assets.isEmpty)

                Button {
                    appState.selectAll()
                } label: {
                    Image(systemName: "checkmark.circle")
                }
                .accessibilityLabel("전체 선택")
                .disabled(appState.isLoadingPhotos || appState.assets.isEmpty)
            }
            ToolbarItem(placement: .topBarLeading) {
                Button {
                    Task { await appState.loadPhotos() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .accessibilityLabel("다시 불러오기")
                .disabled(appState.isLoadingPhotos)
            }
        }
    }

    private var photoLoadingStatus: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                ProgressView(value: appState.photoLoadProgressFraction)
                Text("사진/동영상 불러오는 중")
                    .font(.subheadline.bold())
            }
            Text(appState.photoLoadProgressText)
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 8))
    }

    private var selectionSummary: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label("\(appState.selectedCount)개 선택", systemImage: "checkmark.square")
                Spacer()
                Text(Formatters.selectionSize(appState.selectedTotalSize, selectedCount: appState.selectedCount))
                    .foregroundStyle(.secondary)
            }
            Text("월 전체, 일 전체, 개별 파일 선택을 모두 지원합니다.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .padding(14)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 8))
    }

    private func monthSection(_ month: MonthGroup) -> some View {
        DisclosureGroup {
            VStack(alignment: .leading, spacing: 16) {
                ForEach(month.days) { day in
                    daySection(day)
                }
            }
            .padding(.top, 10)
        } label: {
            HStack {
                VStack(alignment: .leading) {
                    Text(month.title)
                        .font(.headline)
                    Text("\(month.items.count)개")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button {
                    appState.toggleMonth(month)
                } label: {
                    Image(systemName: month.isFullySelected ? "checkmark.square.fill" : "square")
                }
                .buttonStyle(.plain)
                .accessibilityLabel("월 전체 선택")
            }
        }
        .padding(14)
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 8))
    }

    private func daySection(_ day: DayGroup) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(day.title)
                    .font(.subheadline.bold())
                Spacer()
                Button {
                    appState.toggleDay(day)
                } label: {
                    Image(systemName: day.isFullySelected ? "checkmark.square.fill" : "square")
                }
                .buttonStyle(.plain)
                .accessibilityLabel("일 전체 선택")
            }

            LazyVGrid(columns: columns, spacing: 10) {
                ForEach(day.items) { item in
                    AssetCell(item: item) {
                        appState.toggleSelection(item)
                    }
                }
            }
        }
    }
}

struct AssetCell: View {
    let item: PhotoAssetItem
    var onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            VStack(alignment: .leading, spacing: 6) {
                ZStack(alignment: .topTrailing) {
                    ThumbnailView(localIdentifier: item.assetLocalIdentifier)
                        .frame(height: 92)
                        .clipShape(RoundedRectangle(cornerRadius: 8))

                    Image(systemName: item.isSelected ? "checkmark.circle.fill" : "circle")
                        .font(.title3)
                        .foregroundStyle(item.isSelected ? .blue : .white)
                        .shadow(radius: 2)
                        .padding(6)
                }

                HStack(spacing: 4) {
                    Image(systemName: item.mediaType.iconName)
                    Text(item.originalFilename)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .font(.caption)

                HStack {
                    Text(item.transferStatus.title)
                        .foregroundStyle(item.transferStatus.tint)
                    Spacer()
                    Text(Formatters.bytes(item.fileSize))
                }
                .font(.caption2)
                .foregroundStyle(.secondary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

struct ThumbnailView: View {
    let localIdentifier: String
    @State private var image: UIImage?

    var body: some View {
        ZStack {
            Rectangle()
                .fill(Color(.tertiarySystemFill))
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                Image(systemName: "photo")
                    .foregroundStyle(.secondary)
            }
        }
        .task(id: localIdentifier) {
            image = await PhotoLibraryService().thumbnail(
                for: localIdentifier,
                targetSize: CGSize(width: 220, height: 220)
            )
        }
    }
}

struct MovePreparationScreen: View {
    @EnvironmentObject private var appState: AppState

    var body: some View {
        List {
            Section("이동 준비") {
                LabeledContent("선택 파일") { Text("\(appState.selectedCount)개") }
                LabeledContent("총 용량") {
                    Text(Formatters.selectionSize(appState.selectedTotalSize, selectedCount: appState.selectedCount))
                }
                LabeledContent("USB 내보내기 폴더") {
                    Text(appState.usbExportPathText.isEmpty ? "아직 없음" : appState.usbExportPathText)
                        .multilineTextAlignment(.trailing)
                        .textSelection(.enabled)
                }
                Text("선택한 원본을 앱 문서 폴더에 복사한 뒤 Windows 앱에서 PC 하드나 외장하드 대상 폴더로 가져오고 검증합니다.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section("예상 저장 구조") {
                ForEach(appState.selectedItems.prefix(8)) { item in
                    Text(previewPath(for: item))
                        .font(.caption)
                        .textSelection(.enabled)
                }
            }

            Section("USB 내보내기") {
                Button {
                    Task { await appState.prepareUsbExport() }
                } label: {
                    Label("USB 내보내기 만들기", systemImage: "square.and.arrow.down")
                }
                .disabled(!appState.canPrepareUsbExport)

                Text(appState.usbExportMessage)
                    .font(.footnote)
                    .foregroundStyle(.secondary)

                TransferProgressPanel()
            }

            Section("결과") {
                NavigationLink {
                    TransferResultScreen()
                } label: {
                    Label("USB 내보내기 결과", systemImage: "checklist")
                }
            }
        }
        .navigationTitle("이동 준비")
    }

    private func previewPath(for item: PhotoAssetItem) -> String {
        let root = appState.usbExportPathText.isEmpty ? "PhotoMoveBridgeUSBExport/새 내보내기" : appState.usbExportPathText
        guard let date = item.creationDate else {
            return "\(root)/Unknown-Date/\(item.originalFilename)"
        }
        return "\(root)/\(Formatters.monthFolder.string(from: date))/\(Formatters.dayFolder.string(from: date))/\(item.originalFilename)"
    }
}

struct TransferProgressPanel: View {
    @EnvironmentObject private var appState: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if appState.transferIsRunning {
                LabeledContent("현재 파일") { Text(appState.currentFileName).lineLimit(1).truncationMode(.middle) }
                ProgressView(value: appState.currentFileProgress) {
                    Text("현재 파일 진행률")
                }
                ProgressView(value: appState.overallProgress) {
                    Text("전체 진행률")
                }
                HStack {
                    metric("성공", appState.successCount)
                    metric("실패", appState.failedCount)
                    metric("대기", appState.pendingCount)
                    metric("재시도", appState.retryCount)
                }
                LabeledContent("처리 속도") { Text(appState.transferSpeedText) }
                LabeledContent("예상 남은 시간") { Text(appState.estimatedRemainingText) }
            } else {
                Text("작업 대기 중")
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func metric(_ title: String, _ value: Int) -> some View {
        VStack {
            Text("\(value)")
                .font(.headline)
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }
}

struct TransferResultScreen: View {
    @EnvironmentObject private var appState: AppState

    var body: some View {
        List {
            Section("USB 내보내기 완료") {
                if appState.successfulItems.isEmpty {
                    Text("아직 성공 항목이 없습니다.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(appState.successfulItems) { item in
                        ResultRow(item: item)
                    }
                }
            }

            Section("실패") {
                if appState.failedItems.isEmpty {
                    Text("실패 항목이 없습니다.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(appState.failedItems) { item in
                        ResultRow(item: item)
                    }

                    Button {
                        Task { await appState.retryFailedTransfers() }
                    } label: {
                        Label("실패 파일 재시도", systemImage: "arrow.counterclockwise")
                    }
                    .disabled(appState.transferIsRunning)
                }
            }

            Section("Windows 가져오기 검증") {
                if appState.verificationPendingItems.isEmpty {
                    Text(appState.deleteReadyItems.isEmpty
                         ? "USB 내보내기를 만든 뒤 Windows 앱에서 가져오기·SHA256 검증을 완료하세요. 검증이 끝나면 이 화면에서 확인 처리해 iPhone 삭제를 활성화할 수 있습니다."
                         : "검증 확인이 완료되었습니다. 아래 ‘삭제 가능’ 목록에서 iPhone 정리를 진행하세요.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                } else {
                    Text("아래 \(appState.verificationPendingItems.count)개 파일이 USB 내보내기로 복사되었습니다. Windows 앱에서 가져오기·SHA256 검증이 모두 성공한 것을 확인했다면 검증 완료로 표시하세요. 표시 후에만 iPhone 삭제가 가능합니다.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    Button {
                        appState.confirmWindowsVerification()
                    } label: {
                        Label("Windows 가져오기·검증 완료로 표시", systemImage: "checkmark.seal")
                    }
                    .disabled(appState.transferIsRunning)
                }
            }

            Section("삭제 가능") {
                if appState.deleteReadyItems.isEmpty {
                    Text("아직 삭제 가능한 항목이 없습니다. 위 ‘Windows 가져오기 검증’에서 검증 완료로 표시하면 복사가 끝난 항목이 여기에 나타납니다.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(appState.deleteReadyItems) { item in
                        ResultRow(item: item)
                    }
                    NavigationLink {
                        DeleteConfirmationScreen()
                    } label: {
                        Label("복사 완료된 항목만 iPhone에서 삭제", systemImage: "trash")
                    }
                    .disabled(!appState.deleteButtonAvailable)
                }
            }
        }
        .navigationTitle("이동 결과")
    }
}

struct ResultRow: View {
    let item: PhotoAssetItem

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Label(item.originalFilename, systemImage: item.mediaType.iconName)
                Spacer()
                Text(item.transferStatus.title)
                    .font(.caption)
                    .foregroundStyle(item.transferStatus.tint)
            }
            if let path = item.remoteSavedPath {
                Text(path)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
            if let error = item.errorMessage {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
    }
}

struct DeleteConfirmationScreen: View {
    @EnvironmentObject private var appState: AppState

    var body: some View {
        List {
            Section {
                LabeledContent("삭제 대상") { Text("\(appState.deleteReadyItems.count)개") }
                LabeledContent("삭제 대상 총 용량") {
                    Text(Formatters.bytes(appState.deleteReadyItems.reduce(0) { $0 + $1.fileSize }))
                }
                LabeledContent("USB 내보내기 폴더") {
                    Text(appState.usbExportPathText.isEmpty ? "PhotoMoveBridgeUSBExport" : appState.usbExportPathText)
                        .multilineTextAlignment(.trailing)
                }
            }

            Section {
                Text("선택한 사진/동영상은 Windows 저장 대상에 복사 및 검증 완료되었습니다. iPhone에서 삭제를 진행하시겠습니까?")
                    .font(.body)

                Toggle("위 내용을 확인했습니다", isOn: $appState.deleteConfirmationChecked)

                Button(role: .destructive) {
                    Task { await appState.deleteReadyAssetsFromIPhone() }
                } label: {
                    Label("iPhone 사진 보관함에서 삭제", systemImage: "trash.fill")
                }
                .disabled(!appState.deleteConfirmationChecked || !appState.deleteButtonAvailable)
            }

            Section("삭제 대상 목록") {
                ForEach(appState.deleteReadyItems) { item in
                    ResultRow(item: item)
                }
            }
        }
        .navigationTitle("삭제 확인")
    }
}

struct LogScreen: View {
    @EnvironmentObject private var appState: AppState

    var body: some View {
        List {
            if appState.logs.isEmpty {
                ContentUnavailableView("로그 없음", systemImage: "doc.text")
            } else {
                ForEach(appState.logs) { log in
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text(log.originalFilename)
                                .font(.headline)
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Spacer()
                            Text(log.status.title)
                                .font(.caption)
                                .foregroundStyle(log.status.tint)
                        }
                        Text(log.timestamp.formatted(date: .abbreviated, time: .standard))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        if let savedPath = log.savedPath {
                            Text(savedPath)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                        }
                        if let message = log.errorMessage {
                            Text(message)
                                .font(.caption)
                                .foregroundStyle(.red)
                        }
                    }
                    .padding(.vertical, 4)
                }
            }
        }
        .navigationTitle("로그")
        .toolbar {
            Button(role: .destructive) {
                appState.clearLogs()
            } label: {
                Image(systemName: "trash")
            }
            .accessibilityLabel("로그 삭제")
        }
    }
}

// MARK: - Utilities

enum BridgeError: LocalizedError {
    case photoPermissionRequired
    case assetResourceNotFound
    case photoKitDeleteFailed

    var errorDescription: String? {
        switch self {
        case .photoPermissionRequired:
            "사진 보관함 접근 권한이 필요합니다."
        case .assetResourceNotFound:
            "선택한 원본 리소스를 찾을 수 없습니다."
        case .photoKitDeleteFailed:
            "PhotoKit 삭제 요청이 실패했습니다."
        }
    }
}

enum FileUtilities {
    static func fileSize(at url: URL) throws -> Int64 {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        return (attributes[.size] as? NSNumber)?.int64Value ?? 0
    }

    static func sha256HexDigest(for url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }

        var hasher = SHA256()
        while autoreleasepool(invoking: {
            let data = handle.readData(ofLength: 1024 * 1024)
            if data.isEmpty { return false }
            hasher.update(data: data)
            return true
        }) {}

        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    static func safeTemporaryFilename(_ filename: String) -> String {
        let disallowed = CharacterSet(charactersIn: "/\\?%*|\"<>:")
        let cleaned = filename.components(separatedBy: disallowed).joined(separator: "_")
        return cleaned.isEmpty ? "asset.bin" : cleaned
    }

    static func usbExportRootDirectory() throws -> URL {
        let url = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("PhotoMoveBridgeUSBExport", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        try excludeFromBackup(url)
        return url
    }

    /// 파일 공유(Documents)에 노출되지 않는 내부 저장 위치.
    /// 캐시/로그 등 사용자에게 노출할 필요 없는 앱 내부 데이터를 보관합니다.
    static func applicationSupportDirectory() -> URL {
        let url = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static func excludeFromBackup(_ url: URL) throws {
        var resourceValues = URLResourceValues()
        resourceValues.isExcludedFromBackup = true
        var mutableURL = url
        try mutableURL.setResourceValues(resourceValues)
    }

    static func usbRelativePath(for item: PhotoAssetItem, usedPaths: inout Set<String>) -> String {
        let month = item.creationDate.map { Formatters.monthFolder.string(from: $0) } ?? "Unknown-Date"
        let day = item.creationDate.map { Formatters.dayFolder.string(from: $0) } ?? "Unknown-Date"
        let safeName = safeTemporaryFilename(item.originalFilename)
        let stem = (safeName as NSString).deletingPathExtension
        let pathExtension = (safeName as NSString).pathExtension
        var candidate = "\(month)/\(day)/\(safeName)"
        var counter = 1

        while usedPaths.contains(candidate.lowercased()) {
            let dedupedName = pathExtension.isEmpty
                ? "\(stem)_\(counter)"
                : "\(stem)_\(counter).\(pathExtension)"
            candidate = "\(month)/\(day)/\(dedupedName)"
            counter += 1
        }

        usedPaths.insert(candidate.lowercased())
        return candidate
    }

    static func copyFileReplacingExisting(from sourceURL: URL, to destinationURL: URL) throws {
        try FileManager.default.createDirectory(
            at: destinationURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        if FileManager.default.fileExists(atPath: destinationURL.path) {
            try FileManager.default.removeItem(at: destinationURL)
        }
        try FileManager.default.copyItem(at: sourceURL, to: destinationURL)
    }

    static func httpHeaderSafeFilename(_ filename: String) -> String {
        filename.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? filename
    }
}

enum Formatters {
    nonisolated(unsafe) static let iso8601: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    static let monthFolder: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM"
        return formatter
    }()

    static let dayFolder: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    static let exportSession: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter
    }()

    static func bytes(_ count: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: count, countStyle: .file)
    }

    static func selectionSize(_ count: Int64, selectedCount: Int) -> String {
        selectedCount > 0 && count == 0 ? "내보내기 중 계산" : bytes(count)
    }

    static func duration(_ seconds: TimeInterval) -> String {
        if seconds < 60 {
            return "\(Int(seconds))초"
        }
        let minutes = Int(seconds / 60)
        let remainder = Int(seconds) % 60
        return "\(minutes)분 \(remainder)초"
    }

    static func monthKey(for date: Date?) -> String {
        guard let date else { return "0000-00" }
        return monthFolder.string(from: date)
    }

    static func dayKey(for date: Date?) -> String {
        guard let date else { return "0000-00-00" }
        return dayFolder.string(from: date)
    }

    static func monthTitle(for date: Date?) -> String {
        guard let date else { return "촬영일 없음" }
        return monthFolder.string(from: date)
    }

    static func dayTitle(for date: Date?) -> String {
        guard let date else { return "촬영일 없음" }
        return dayFolder.string(from: date)
    }
}

enum PhotoGrouping {
    static func makeMonthGroups(from assets: [PhotoAssetItem]) -> [MonthGroup] {
        let grouped = Dictionary(grouping: assets) { item in
            Formatters.monthKey(for: item.creationDate)
        }

        return grouped.keys.sorted(by: >).map { key in
            let items = grouped[key, default: []].sortedForDisplay()
            let dayGroups = Dictionary(grouping: items) { item in
                Formatters.dayKey(for: item.creationDate)
            }
            let days = dayGroups.keys.sorted(by: >).map { dayKey in
                let dayItems = dayGroups[dayKey, default: []].sortedForDisplay()
                return DayGroup(
                    id: dayKey,
                    title: Formatters.dayTitle(for: dayItems.first?.creationDate),
                    selectedCount: dayItems.lazy.filter(\.isSelected).count,
                    items: dayItems
                )
            }
            return MonthGroup(
                id: key,
                title: Formatters.monthTitle(for: items.first?.creationDate),
                selectedCount: items.lazy.filter(\.isSelected).count,
                items: items,
                days: days
            )
        }
    }
}

enum PhotoAssetCache {
    static var url: URL {
        FileUtilities.applicationSupportDirectory()
            .appendingPathComponent("PhotoMoveBridgeAssetCache.json")
    }

    static func load() -> [PhotoAssetItem] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        return (try? JSONDecoder.bridgeDecoder.decode([PhotoAssetItem].self, from: data)) ?? []
    }

    static func save(_ assets: [PhotoAssetItem]) {
        guard let data = try? JSONEncoder.bridgeEncoder.encode(assets) else { return }
        try? data.write(to: url, options: [.atomic])
    }
}

enum LogStore {
    static var url: URL {
        FileUtilities.applicationSupportDirectory()
            .appendingPathComponent("PhotoMoveBridgeLogs.json")
    }

    static func load() -> [TransferLog] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        return (try? JSONDecoder.bridgeDecoder.decode([TransferLog].self, from: data)) ?? []
    }

    static func save(_ logs: [TransferLog]) {
        guard let data = try? JSONEncoder.bridgeEncoder.encode(logs) else { return }
        try? data.write(to: url, options: [.atomic])
    }
}

extension JSONEncoder {
    static var bridgeEncoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }
}

extension JSONDecoder {
    static var bridgeDecoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}

extension Array where Element == PhotoAssetItem {
    func sortedForDisplay() -> [PhotoAssetItem] {
        sorted {
            switch ($0.creationDate, $1.creationDate) {
            case let (lhs?, rhs?):
                if lhs != rhs { return lhs > rhs }
                return $0.originalFilename < $1.originalFilename
            case (.some, .none):
                return true
            case (.none, .some):
                return false
            case (.none, .none):
                return $0.originalFilename < $1.originalFilename
            }
        }
    }
}

extension URL {
    func appendingRelativePath(_ relativePath: String) -> URL {
        relativePath
            .split(separator: "/")
            .reduce(self) { partialURL, component in
                partialURL.appendingPathComponent(String(component))
            }
    }
}

extension UIApplication {
    var activeRootViewController: UIViewController? {
        connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
            .first { $0.isKeyWindow }?
            .rootViewController
    }
}

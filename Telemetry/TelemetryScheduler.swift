//
//  TelemetryScheduler.swift
//  Telemetry
//
//  Created by Justin D'Arcangelo on 4/18/17.
//
//

import Foundation

public class TelemetryScheduler {
    private let configuration: TelemetryConfiguration
    private let storage: TelemetryStorage
    
    private let client: TelemetryClient
    
    init(configuration: TelemetryConfiguration, storage: TelemetryStorage) {
        self.configuration = configuration
        self.storage = storage
        self.client = TelemetryClient(configuration: configuration)
    }
    
    public func scheduleUpload(pingType: String, completionHandler: @escaping () -> Void) {
        storage.markPingFileReadyForUpload(pingType: pingType)
        var filesAndPings = storage.readAllFilesReadyForUpload(pingType: pingType)
        if filesAndPings.count == 0 {
            completionHandler()
            return
        }

        var currentFile = filesAndPings.remove(at: 0)

        func sequentialPingUploader() {
            if hasReachedDailyUploadLimitForPingType(pingType) {
                completionHandler()
                return
            }

            if currentFile.dicts.count == 0 {
                if filesAndPings.count > 0 {
                    currentFile = filesAndPings.remove(at: 0)
                    sequentialPingUploader()
                } else {
                    completionHandler()
                }
                return
            }

            guard let ping = TelemetryPing.from(dictionary: currentFile.dicts.remove(at: 0)) else {
                let error = NSError(domain: TelemetryError.ErrorDomain, code: TelemetryError.CannotGeneratePing, userInfo: [NSLocalizedDescriptionKey: "Ping to JSON conversion failure."])
                NotificationCenter.default.post(name: Telemetry.notificationUploadError, object: nil, userInfo: ["error": error])

                storage.writeOrDelete(file: currentFile.filename, dicts: currentFile.dicts)
                sequentialPingUploader()
                return
            }

            client.upload(ping: ping) { httpStatusCode, error in
                let errorCode = (error as NSError?)?.code ?? 0
                let errorRequiresDelete = [TelemetryError.InvalidUploadURL, TelemetryError.CannotGenerateJSON].contains(errorCode)

                // Arguably, this could be (200..<500).contains(httpStatusCode) and 5xx errors could be handled more selectively to decide whether to delete the ping.
                if httpStatusCode >= 200 || errorRequiresDelete {
                    // Network call completed, successful or with error, delete the ping, and upload the next ping.
                    self.storage.writeOrDelete(file: currentFile.filename, dicts: currentFile.dicts)
                    self.incrementDailyUploadCountForPingType(pingType)
                    sequentialPingUploader()
                } else {
                    // Stops uploading.
                    completionHandler()
                }
            }
        }

        sequentialPingUploader()
    }

    private func dailyUploadCountForPingType(_ pingType: String) -> Int {
        return storage.get(valueFor: "\(pingType)-dailyUploadCount") as? Int ?? 0
    }
    
    private func lastUploadTimestampForPingType(_ pingType: String) -> TimeInterval {
        return storage.get(valueFor: "\(pingType)-lastUploadTimestamp") as? TimeInterval ?? Date().timeIntervalSince1970
    }
    
    private func incrementDailyUploadCountForPingType(_ pingType: String) {
        let dailyUploadCount = dailyUploadCountForPingType(pingType) + 1
        storage.set(key: "\(pingType)-dailyUploadCount", value: dailyUploadCount)
        
        let lastUploadTimestamp = Date().timeIntervalSince1970
        storage.set(key: "\(pingType)-lastUploadTimestamp", value: lastUploadTimestamp)
    }
    
    private func hasReachedDailyUploadLimitForPingType(_ pingType: String) -> Bool {
        if !isTimestampFromToday(timestamp: lastUploadTimestampForPingType(pingType)) {
            return false
        }
        
        return dailyUploadCountForPingType(pingType) >= configuration.maximumNumberOfPingUploadsPerDay
    }
    
    private func isTimestampFromToday(timestamp: TimeInterval) -> Bool {
        let dateA = Date(timeIntervalSince1970: timestamp)
        let dayA = Calendar.current.component(.day, from: dateA)
        let monthA = Calendar.current.component(.month, from: dateA)
        let yearA = Calendar.current.component(.year, from: dateA)

        let dateB = Date()
        let dayB = Calendar.current.component(.day, from: dateB)
        let monthB = Calendar.current.component(.month, from: dateB)
        let yearB = Calendar.current.component(.year, from: dateB)
        
        return dayA == dayB && monthA == monthB && yearA == yearB
    }
}

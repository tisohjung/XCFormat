//
//  FormatterCommand.swift
//  SourceExtension
//
//  Created by Steven Mok on 2018/8/2.
//  Copyright © 2018年 sugarmo. All rights reserved.
//

import Cocoa
import XcodeKit

private let formatActiveFile = "FormatActiveFile"
private let formatSelctedLines = "FormatSelctedLines"

private enum FormatterError: Error {
    case failure(reason: String)
}

class FormatterCommand: NSObject, XCSourceEditorCommand {
    private var completion: CommandCompletion?
    private var task: Process?
    private var temporaryFolderURL: URL?

    private func error(with reason: String) -> FormatterError {
        return FormatterError.failure(reason: reason)
    }

    private static let uncrustifyPath: String? = {
        Bundle.main.path(forResource: "uncrustify", ofType: nil)
    }()

    private static let uncrustifyConfigPath: String? = {
        Bundle.main.path(forResource: "uncrustify", ofType: "cfg")
    }()

    private func convertStringToLines(_ string: String) -> [String] {
        let comps = string.components(separatedBy: "\n")
        var result = comps
        if result.last == "" {
            result.removeLast()
        }
        return result
    }

    private func cancel() {
        task?.terminate()
        cleanup()
    }

    private func createTemporayFolder() throws -> URL? {
        let rootURL = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        let temporaryFolderURL = rootURL.appendingPathComponent(UUID().uuidString, isDirectory: true)

        try FileManager.default.createDirectory(at: temporaryFolderURL, withIntermediateDirectories: true, attributes: nil)

        return temporaryFolderURL
    }

    private func cleanup() {
        if let url = temporaryFolderURL {
            try? FileManager.default.removeItem(at: url)
        }
        temporaryFolderURL = nil
        completion = nil
        task = nil
    }

    private func didSucceedPerformCommand() {
        completion?(nil)
        cleanup()
    }

    private func didFailedPerformCommand(_ error: Error) {
        completion?(error)
        cleanup()
    }

    func perform(with invocation: XCSourceEditorCommandInvocation, completionHandler: @escaping (Error?) -> Void) {
        do {
            try temporaryFolderURL = createTemporayFolder()

            invocation.cancellationHandler = {
                self.cancel()
            }
            completion = completionHandler

            task = try makeTask(with: invocation)
            task?.launch(with: .none)

            while task != nil {
                RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.1))
            }
        } catch let error {
            didFailedPerformCommand(error)
            return
        }
    }

    private func taskDidTerminated(_ terminationStatus: Int32,
                                   invocation: XCSourceEditorCommandInvocation,
                                   selectedLineRange: NSRange,
                                   sourceFileURL: URL) {
        do {
            if terminationStatus == 0 {
                let formattedSubstring = try String(contentsOf: sourceFileURL, encoding: .utf8)

                if selectedLineRange.location != NSNotFound {
                    let outputLines = convertStringToLines(formattedSubstring)
                    if outputLines.count > 0 {
                        invocation.buffer.lines.replaceObjects(in: selectedLineRange, withObjectsFrom: outputLines)
                        didSucceedPerformCommand()
                        return
                    } else {
                        throw FormatterError.failure(reason: "Output lines convert failed.")
                    }
                } else {
                    if let preSelection = invocation.buffer.selections.firstObject {
                        invocation.buffer.completeBuffer = formattedSubstring
                        invocation.buffer.selections.setArray([preSelection])
                    }
                    didSucceedPerformCommand()
                    return
                }
            } else {
                if let errorData = task?.standardErrorHandle()?.readDataToEndOfFile(), let reason = String(data: errorData, encoding: .utf8) {
                    throw FormatterError.failure(reason: reason)
                } else {
                    throw FormatterError.failure(reason: "Uncrustify error — exit code \(terminationStatus)")
                }
            }
        } catch let error {
            didFailedPerformCommand(error)
            return
        }
    }

    private func makeTask(with invocation: XCSourceEditorCommandInvocation) throws -> Process {
        var args = [String]()

        args.append("--no-backup")

        let uti = invocation.buffer.contentUTI

        let isObjectiveCFile = NSWorkspace.shared.type(uti, conformsToType: kUTTypeObjectiveCSource as String)
        if isObjectiveCFile {
            args.append(contentsOf: ["-l", "OC"])
        }

        var isFragmented = false
        if invocation.commandIdentifier.hasSuffix(formatSelctedLines) {
            isFragmented = true
        }

        if isFragmented {
            args.append("--frag")
        }

        args.append(contentsOf: ["-c", type(of: self).uncrustifyConfigPath] as! [String])

        let sourceFileURL = temporaryFolderURL!.appendingPathComponent("sourcecode", isDirectory: false)
        args.append(sourceFileURL.path)

        let errorPipe = Pipe()

        var selectedLineRange = NSMakeRange(NSNotFound, 0)
        if isFragmented {
            let selectedTextRange = invocation.buffer.selections.firstObject as! XCSourceTextRange
            selectedLineRange = NSMakeRange(selectedTextRange.start.line, selectedTextRange.end.line - selectedTextRange.start.line + 1)
            let selectedLines = invocation.buffer.lines.subarray(with: selectedLineRange) as NSArray
            let selectedString = selectedLines.componentsJoined(by: "")
            try selectedString.write(to: sourceFileURL, atomically: true, encoding: .utf8)
        } else {
            try invocation.buffer.completeBuffer.write(to: sourceFileURL, atomically: true, encoding: .utf8)
        }

        let task = Process()
        task.standardError = errorPipe
        task.launchPath = type(of: self).uncrustifyPath
        task.arguments = args

        task.addTerminateBlock { (terminationStatus: Int32) in
            self.taskDidTerminated(terminationStatus, invocation: invocation, selectedLineRange: selectedLineRange, sourceFileURL: sourceFileURL)
        }

        return task
    }
}
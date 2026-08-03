//
//  NewProjectDialog.swift
//  Compass
//
//  Created by Jack Trefon on 25/12/2025.
//

import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct NewProjectDialog: View {
    @State private var projectLocation: URL?
    @State private var projectName: String = ""
    @State private var isCreating: Bool = false
    @Environment(\.dismiss) private var dismiss

    private let fileDialogService: FileDialogServiceProtocol
    private let onCreateProject: (URL, String) async -> Void

    init(
        fileDialogService: FileDialogServiceProtocol,
        onCreateProject: @escaping (URL, String) async -> Void
    ) {
        self.fileDialogService = fileDialogService
        self.onCreateProject = onCreateProject
    }

    var body: some View {
        VStack(spacing: 20) {
            Text(NSLocalizedString("new_project.title", comment: ""))
                .font(.title2)
                .fontWeight(.semibold)

            VStack(alignment: .leading, spacing: 8) {
                Text(NSLocalizedString("new_project.project_location", comment: ""))
                    .font(.headline)

                HStack {
                    Text(projectLocation?.path ?? NSLocalizedString("new_project.no_location_selected", comment: ""))
                        .foregroundColor(projectLocation != nil ? .primary : .secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, AppConstants.Layout.spacingSm)
                        .padding(.vertical, AppConstants.Layout.spacingXS)
                        .background(AppConstants.Color.surfaceCard)
                        .cornerRadius(AppConstants.Layout.cornerXs)

                    Button(NSLocalizedString("new_project.browse", comment: "")) {
                        Task {
                            await selectLocation()
                        }
                    }
                    .buttonStyle(.bordered)
                }
            }

            VStack(alignment: .leading, spacing: 8) {
                Text(NSLocalizedString("new_project.project_name", comment: ""))
                    .font(.headline)

                TextField(NSLocalizedString("new_project.enter_project_name", comment: ""), text: $projectName)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit {
                        if canCreateProject {
                            Task {
                                await createProject()
                            }
                        }
                    }
            }

            if !projectName.isEmpty && !isValidProjectName(projectName) {
                Text(NSLocalizedString("new_project.invalid_project_name", comment: ""))
                    .font(.caption)
                    .foregroundStyle(AppConstants.Color.alertError)
            }

            HStack {
                Button(NSLocalizedString("common.cancel", comment: "")) {
                    dismiss()
                }
                .keyboardShortcut(.escape)

                Spacer()

                Button(NSLocalizedString("common.create", comment: "")) {
                    Task {
                        await createProject()
                    }
                }
                .disabled(!canCreateProject || isCreating)
                .keyboardShortcut(.return)
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(AppConstants.Layout.spacingLg)
        .frame(width: 400, height: 250)
        .onAppear {
            // Set initial focus to project name field
            Task {
                try? await Task.sleep(nanoseconds: 100_000_000)
                await MainActor.run {
                    NSApp.keyWindow?.makeFirstResponder(nil)
                }
            }
        }
    }

    private var canCreateProject: Bool {
        guard projectLocation != nil else { return false }
        return !projectName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && isValidProjectName(projectName)
    }

    private func isValidProjectName(_ name: String) -> Bool {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)

        // Check for empty or whitespace-only names
        guard !trimmedName.isEmpty else { return false }

        // Check for path traversal attempts
        if trimmedName.contains("..") || trimmedName.contains("/") {
            return false
        }

        // Check for invalid characters
        let invalidChars = CharacterSet(charactersIn: ":*?\"<>|")
        guard trimmedName.rangeOfCharacter(from: invalidChars) == nil else {
            return false
        }

        // Check reserved names
        let reservedNames = [
            "CON", "PRN", "AUX", "NUL",
            "COM1", "COM2", "COM3", "COM4", "COM5", "COM6", "COM7", "COM8", "COM9",
            "LPT1", "LPT2", "LPT3", "LPT4", "LPT5", "LPT6", "LPT7", "LPT8", "LPT9"
        ]
        if reservedNames.contains(trimmedName.uppercased()) {
            return false
        }

        // Check name length
        if trimmedName.count > 255 {
            return false
        }

        return true
    }

    private func selectLocation() async {
        if let url = await fileDialogService.promptForNewProjectFolder(
            defaultName: projectName.isEmpty ? "NewProject" : projectName
        ) {
            projectLocation = url.deletingLastPathComponent()
            if projectName.isEmpty {
                projectName = url.lastPathComponent
            }
        }
    }

    private func createProject() async {
        guard let location = projectLocation,
              !projectName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return
        }

        isCreating = true
        defer { isCreating = false }

        await onCreateProject(location, projectName.trimmingCharacters(in: .whitespacesAndNewlines))
        dismiss()
    }
}

import SwiftUI
import Shared
import UIKit
import PhotosUI

struct BackgroundPickerView: View {
    let allBackgrounds: [String]
    @Binding var selectedBackground: String
    
    @State private var backgrounds: [String] = []
    @State private var selectedItem: PhotosPickerItem?
    @State private var isShowingPhotoPicker = false
    @State private var isSaving = false
    @State private var saveErrorMessage: String?
    @State private var deleteCandidate: String?
    @State private var isShowingDeleteConfirmation = false
    @State private var deleteErrorMessage: String?
    
    private let gridSpacing: CGFloat = 16
    private let gridPadding: CGFloat = 16
    private var previewAspectRatio: CGFloat {
        let size = UIScreen.main.bounds.size
        guard size.height > 0 else { return 9.0 / 16.0 }
        return size.width / size.height
    }
    
    var body: some View {
        GeometryReader { proxy in
            let availableWidth = proxy.size.width - gridPadding * 2
            let itemWidth = max((availableWidth - gridSpacing) / 2, 0)
            let itemHeight = itemWidth / previewAspectRatio
            let columns = [
                GridItem(.fixed(itemWidth), spacing: gridSpacing),
                GridItem(.fixed(itemWidth), spacing: gridSpacing)
            ]
            
            ScrollView {
                LazyVGrid(columns: columns, spacing: gridSpacing) {
                    ForEach(backgrounds, id: \.self) { name in
                        Button {
                            selectedBackground = name
                        } label: {
                            FileImage(filename: name)
                                .aspectRatio(previewAspectRatio, contentMode: .fill)
                                .frame(width: itemWidth, height: itemHeight)
                                .clipped()
                                .overlay {
                                    RoundedRectangle(cornerRadius: 14)
                                        .stroke(selectedBackground == name ? Color.accentColor : .clear, lineWidth: 4)
                                }
                                .clipShape(RoundedRectangle(cornerRadius: 14))
                        }
                        .buttonStyle(.plain)
                        .contextMenu {
                            Button(role: .destructive) {
                                deleteCandidate = name
                                isShowingDeleteConfirmation = true
                            } label: {
                                Label("删除", systemImage: "trash")
                            }
                        }
                    }
                }
                .padding(.horizontal, gridPadding)
                .padding(.vertical, gridPadding)
            }
        }
        .navigationTitle("选择背景")
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button {
                    isShowingPhotoPicker = true
                } label: {
                    Image(systemName: "plus")
                }
                .disabled(isSaving)
            }
        }
        .photosPicker(isPresented: $isShowingPhotoPicker, selection: $selectedItem, matching: .images)
        .onChange(of: selectedItem) { _, newItem in
            guard let newItem else { return }
            Task {
                await addBackground(from: newItem)
            }
        }
        .alert("无法保存背景", isPresented: Binding(get: {
            saveErrorMessage != nil
        }, set: { newValue in
            if !newValue {
                saveErrorMessage = nil
            }
        })) {
            Button("确定", role: .cancel) {}
        } message: {
            Text(saveErrorMessage ?? "")
        }
        .alert("删除背景", isPresented: $isShowingDeleteConfirmation, presenting: deleteCandidate) { name in
            Button("删除", role: .destructive) {
                deleteCandidate = nil
                Task {
                    await deleteBackground(named: name)
                }
            }
            Button("取消", role: .cancel) {
                deleteCandidate = nil
            }
        } message: { _ in
            Text("确定删除这张背景吗？")
        }
        .alert("无法删除背景", isPresented: Binding(get: {
            deleteErrorMessage != nil
        }, set: { newValue in
            if !newValue {
                deleteErrorMessage = nil
            }
        })) {
            Button("确定", role: .cancel) {}
        } message: {
            Text(deleteErrorMessage ?? "")
        }
        .task {
            let loaded = ConfigLoader.loadBackgroundImages()
            backgrounds = loaded.isEmpty ? allBackgrounds : loaded
        }
    }
    
    private func addBackground(from item: PhotosPickerItem) async {
        await MainActor.run {
            isSaving = true
        }
        defer {
            Task { @MainActor in
                isSaving = false
            }
        }
        
        guard let data = try? await item.loadTransferable(type: Data.self) else {
            await showSaveError("无法读取图片数据。")
            return
        }
        guard let image = UIImage(data: data) else {
            await showSaveError("无法解析图片。")
            return
        }
        guard let jpegData = image.jpegData(compressionQuality: 0.9) else {
            await showSaveError("无法处理图片格式。")
            return
        }
        
        ConfigLoader.setupBackgroundsDirectory()
        let filename = "background-\(UUID().uuidString).jpg"
        let url = ConfigLoader.getBackgroundsDirectory().appendingPathComponent(filename)
        
        do {
            try jpegData.write(to: url, options: [.atomic])
        } catch {
            await showSaveError("保存失败：\(error.localizedDescription)")
            return
        }
        
        await MainActor.run {
            selectedBackground = filename
            backgrounds = ConfigLoader.loadBackgroundImages()
            NotificationCenter.default.post(name: .syncBackgroundsUpdated, object: nil)
            selectedItem = nil
        }
    }

    private func deleteBackground(named name: String) async {
        let url = ConfigLoader.getBackgroundsDirectory().appendingPathComponent(name)
        do {
            try FileManager.default.removeItem(at: url)
        } catch {
            await MainActor.run {
                deleteErrorMessage = "删除失败：\(error.localizedDescription)"
            }
            return
        }

        await MainActor.run {
            let updated = ConfigLoader.loadBackgroundImages()
            backgrounds = updated
            if !updated.contains(selectedBackground) {
                selectedBackground = updated.first ?? ""
            }
            NotificationCenter.default.post(name: .syncBackgroundsUpdated, object: nil)
        }
    }
    
    @MainActor
    private func showSaveError(_ message: String) {
        saveErrorMessage = message
        selectedItem = nil
    }
}

private struct FileImage: View {
    let filename: String
    @State private var image: UIImage?
    
    var body: some View {
        Group {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                ZStack {
                    Rectangle().fill(Color.secondary.opacity(0.1))
                    ProgressView()
                }
            }
        }
        .task {
            await loadImage()
        }
    }
    
    private func loadImage() async {
        let url = ConfigLoader.getBackgroundsDirectory().appendingPathComponent(filename)
        if let loaded = UIImage(contentsOfFile: url.path) {
            await MainActor.run {
                image = loaded
            }
        }
    }
}

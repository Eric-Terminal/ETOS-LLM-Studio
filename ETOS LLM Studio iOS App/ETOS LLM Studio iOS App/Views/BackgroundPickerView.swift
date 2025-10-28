import SwiftUI
import Shared
import UIKit

struct BackgroundPickerView: View {
    let allBackgrounds: [String]
    @Binding var selectedBackground: String
    
    private let columns = [GridItem(.flexible()), GridItem(.flexible())]
    
    var body: some View {
        ScrollView {
            LazyVGrid(columns: columns, spacing: 16) {
                ForEach(allBackgrounds, id: \.self) { name in
                    Button {
                        selectedBackground = name
                    } label: {
                        FileImage(filename: name)
                            .aspectRatio(1.4, contentMode: .fill)
                            .frame(maxWidth: .infinity, minHeight: 120)
                            .clipped()
                            .overlay {
                                RoundedRectangle(cornerRadius: 14)
                                    .stroke(selectedBackground == name ? Color.accentColor : .clear, lineWidth: 4)
                            }
                            .clipShape(RoundedRectangle(cornerRadius: 14))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding()
        }
        .navigationTitle("选择背景")
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

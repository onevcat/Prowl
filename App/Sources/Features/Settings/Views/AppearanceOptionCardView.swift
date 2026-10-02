import SwiftUI

struct AppearanceOptionCardView: View {
  let mode: AppearanceMode
  let isSelected: Bool
  let action: () -> Void

  var body: some View {
    let strokeColor = isSelected ? Color.accentColor : Color.secondary.opacity(0.35)

    Button(action: action) {
      VStack {
        ZStack {
          RoundedRectangle(cornerRadius: 12)
            .fill(mode.previewBackground)
          VStack(alignment: .leading) {
            HStack {
              Circle()
                .fill(.red)
                .frame(width: 6, height: 6)
              Circle()
                .fill(.yellow)
                .frame(width: 6, height: 6)
              Circle()
                .fill(.green)
                .frame(width: 6, height: 6)
            }
            RoundedRectangle(cornerRadius: 3)
              .fill(mode.previewPrimary)
              .frame(height: 10)
            RoundedRectangle(cornerRadius: 3)
              .fill(mode.previewSecondary)
              .frame(height: 8)
            RoundedRectangle(cornerRadius: 3)
              .fill(mode.previewAccent)
              .frame(width: 64, height: 6)
          }
          .padding()
        }
        .aspectRatio(1.6, contentMode: .fit)
        Text(mode.title)
          .font(.headline)
      }
      .frame(maxWidth: .infinity)
      .padding()
    }
    .buttonStyle(.plain)
    .background(isSelected ? Color.accentColor.opacity(0.12) : .clear)
    .clipShape(.rect(cornerRadius: 12))
    .overlay {
      RoundedRectangle(cornerRadius: 12)
        .stroke(strokeColor, lineWidth: isSelected ? 2 : 1)
    }
  }
}

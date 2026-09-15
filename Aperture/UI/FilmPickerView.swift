import SwiftUI

struct FilmPickerView: View {
  @Binding var selectedFilm: FilmRecipeIdentifier
  @Environment(\.dismiss) private var dismiss

  var body: some View {
    NavigationStack {
      ZStack {
        ApertureStyle.ink.ignoresSafeArea()
        VStack(alignment: .leading, spacing: 14) {
          Text("Three films. No editing required.")
            .font(.subheadline)
            .foregroundStyle(ApertureStyle.muted)
            .padding(.horizontal, 20)

          ForEach(FilmRecipeCatalog.all) { film in
            filmButton(film)
          }
          Spacer()
        }
        .padding(.top, 14)
      }
      .navigationTitle("Choose Film")
      .navigationBarTitleDisplayMode(.inline)
      .toolbarColorScheme(.dark, for: .navigationBar)
      .toolbar {
        ToolbarItem(placement: .confirmationAction) {
          Button("Done") { dismiss() }
            .foregroundStyle(ApertureStyle.amber)
        }
      }
    }
    .presentationDetents([.medium])
    .presentationDragIndicator(.visible)
    .preferredColorScheme(.dark)
  }

  private func filmButton(_ film: FilmRecipe) -> some View {
    Button {
      selectedFilm = film.id
      dismiss()
    } label: {
      HStack(spacing: 16) {
        RoundedRectangle(cornerRadius: 4)
          .fill(swatch(for: film.id))
          .frame(width: 8, height: 54)
        VStack(alignment: .leading, spacing: 4) {
          Text(film.displayName)
            .font(.headline)
            .foregroundStyle(ApertureStyle.bone)
          Text(description(for: film.id))
            .font(.caption)
            .foregroundStyle(ApertureStyle.muted)
            .multilineTextAlignment(.leading)
        }
        Spacer()
        if selectedFilm == film.id {
          Image(systemName: "checkmark.circle.fill")
            .foregroundStyle(ApertureStyle.amber)
            .accessibilityHidden(true)
        }
      }
      .padding(.horizontal, 18)
      .padding(.vertical, 12)
      .frame(minHeight: 44)
      .background(RoundedRectangle(cornerRadius: 14).fill(ApertureStyle.panel))
      .padding(.horizontal, 16)
    }
    .buttonStyle(.plain)
    .accessibilityLabel(film.displayName)
    .accessibilityValue(selectedFilm == film.id ? "Selected" : "Not selected")
    .accessibilityHint(description(for: film.id))
  }

  private func swatch(for id: FilmRecipeIdentifier) -> LinearGradient {
    let colors: [Color]
    switch id {
    case .night:
      colors = [.indigo, .orange]
    case .cinema:
      colors = [.teal.opacity(0.8), .yellow.opacity(0.7)]
    default:
      colors = [.orange, .red.opacity(0.8)]
    }
    return LinearGradient(colors: colors, startPoint: .top, endPoint: .bottom)
  }

  private func description(for id: FilmRecipeIdentifier) -> String {
    switch id {
    case .night:
      "Deep blacks, cool shadows, and warm halation."
    case .cinema:
      "Soft contrast with restrained color and gentle highlights."
    default:
      "Warm color, fine grain, and an occasional edge leak."
    }
  }
}

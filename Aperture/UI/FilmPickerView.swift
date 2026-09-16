import SwiftUI

struct FilmPickerView: View {
  @Binding var selectedFilm: FilmRecipeIdentifier
  @Environment(\.dismiss) private var dismiss

  var body: some View {
    NavigationStack {
      ZStack {
        ApertureStyle.ink.ignoresSafeArea()
        ScrollView {
          VStack(alignment: .leading, spacing: 18) {
            header
            VStack(spacing: 10) {
              ForEach(FilmRecipeCatalog.all) { film in
                filmButton(film)
              }
            }
            .padding(.horizontal, 16)

            Text("Aperture develops each frame in the background. Pick a character and keep shooting.")
              .font(.caption)
              .foregroundStyle(ApertureStyle.quiet)
              .multilineTextAlignment(.center)
              .frame(maxWidth: .infinity)
              .padding(.horizontal, 30)
              .padding(.top, 2)
          }
          .padding(.top, 8)
          .padding(.bottom, 26)
        }
        .scrollIndicators(.hidden)
      }
      .navigationTitle("Choose Film")
      .navigationBarTitleDisplayMode(.inline)
      .toolbarColorScheme(.dark, for: .navigationBar)
      .toolbar {
        ToolbarItem(placement: .confirmationAction) {
          Button("Done") { dismiss() }
            .foregroundStyle(ApertureStyle.amber)
            .fontWeight(.semibold)
        }
      }
    }
    .presentationDetents([.medium])
    .presentationDragIndicator(.visible)
    .preferredColorScheme(.dark)
  }

  private var header: some View {
    VStack(alignment: .leading, spacing: 8) {
      ApertureSectionLabel("Film stock", detail: "\(FilmRecipeCatalog.all.count) recipes")
      HStack(alignment: .firstTextBaseline, spacing: 8) {
        Text("Three films.")
          .font(.title2.weight(.semibold))
          .foregroundStyle(ApertureStyle.bone)
        Text("No editing required.")
          .font(.subheadline)
          .foregroundStyle(ApertureStyle.muted)
      }
      Text("Each recipe gives the Lab a different point of view.")
        .font(.subheadline)
        .foregroundStyle(ApertureStyle.muted)
    }
    .padding(.horizontal, 20)
  }

  private func filmButton(_ film: FilmRecipe) -> some View {
    Button {
      selectedFilm = film.id
      dismiss()
    } label: {
      HStack(spacing: 14) {
        RoundedRectangle(cornerRadius: 8, style: .continuous)
          .fill(swatch(for: film.id))
          .frame(width: 42, height: 62)
          .overlay {
            VStack(spacing: 4) {
              Circle().fill(.white.opacity(0.42)).frame(width: 4, height: 4)
              Rectangle().fill(.white.opacity(0.22)).frame(width: 15, height: 1)
              Rectangle().fill(.white.opacity(0.16)).frame(width: 10, height: 1)
            }
          }
          .accessibilityHidden(true)
        VStack(alignment: .leading, spacing: 5) {
          HStack(spacing: 7) {
            Text(film.displayName)
              .font(.headline)
              .foregroundStyle(ApertureStyle.bone)
            if selectedFilm == film.id {
              Text("CURRENT")
                .font(.system(size: 9, weight: .bold, design: .rounded))
                .tracking(0.8)
                .foregroundStyle(ApertureStyle.accent(for: film.id))
            }
          }
          Text(description(for: film.id))
            .font(.caption)
            .foregroundStyle(ApertureStyle.muted)
            .multilineTextAlignment(.leading)
            .fixedSize(horizontal: false, vertical: true)
        }
        Spacer()
        if selectedFilm == film.id {
          Image(systemName: "checkmark.circle.fill")
            .font(.title3)
            .foregroundStyle(ApertureStyle.accent(for: film.id))
            .accessibilityHidden(true)
        }
      }
      .padding(.horizontal, 14)
      .padding(.vertical, 12)
      .frame(minHeight: 86)
      .background(ApertureStyle.panel, in: RoundedRectangle(cornerRadius: ApertureStyle.cardRadius, style: .continuous))
      .overlay(alignment: .leading) {
        RoundedRectangle(cornerRadius: 2, style: .continuous)
          .fill(ApertureStyle.accent(for: film.id))
          .frame(width: 3, height: 34)
          .padding(.leading, 2)
      }
      .overlay {
        RoundedRectangle(cornerRadius: ApertureStyle.cardRadius, style: .continuous)
          .stroke(selectedFilm == film.id ? ApertureStyle.accent(for: film.id).opacity(0.7) : ApertureStyle.line, lineWidth: selectedFilm == film.id ? 1.5 : 1)
      }
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
      colors = [Color(red: 0.16, green: 0.21, blue: 0.29), Color(red: 0.47, green: 0.57, blue: 0.65)]
    case .cinema:
      colors = [Color(red: 0.28, green: 0.30, blue: 0.31), Color(red: 0.69, green: 0.60, blue: 0.44)]
    default:
      colors = [Color(red: 0.42, green: 0.20, blue: 0.16), Color(red: 0.83, green: 0.57, blue: 0.31)]
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

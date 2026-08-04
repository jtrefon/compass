import SwiftUI

struct ModelSuggestionList: View {
    let models: [OpenRouterModel]
    let onSelect: (OpenRouterModel) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(String(format: localized("model_suggestions.matches_format"), models.count))
                .font(.caption)
                .foregroundStyle(.secondary)

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 6) {
                    ForEach(models) { model in
                        Button {
                            onSelect(model)
                        } label: {
                            HStack {
                                Text(model.displayName)
                                    .font(.body)

                                Spacer()

                                Text(model.id)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            .padding(.horizontal, 10)
                            .padding(.vertical, 8)
                        }
                        .buttonStyle(.plain)
                        .background(AppConstants.Color.surfaceCard.opacity(0.3))
                        .clipShape(RoundedRectangle(cornerRadius: AppConstants.Layout.cornerMd, style: .continuous))
                    }
                }
            }
            .frame(maxHeight: 220)
        }
        .padding(10)
        .nativeGlassBackground(.popover, cornerRadius: AppConstants.Layout.cornerLg)
    }
}

import ComposableArchitecture
import ProwlCLIShared
import SwiftUI

struct WorkflowBundleReviewView: View {
  let store: StoreOf<WorkflowSettingsDetailFeature>

  var body: some View {
    if let review = store.bundleReview {
      VStack(alignment: .leading, spacing: 16) {
        Text("Review Workflow Bundle").font(.title2.bold())
        Text(review.snapshot.source.path).font(.callout.monospaced()).textSelection(.enabled)
        Text(
          """
          Scripts can read and change files, use the network, and run programs with your permissions.
          Approval applies to every file in this version of the bundle.
          """
        )
        .fixedSize(horizontal: false, vertical: true)
        ForEach(review.scripts, id: \.id) { script in
          LabeledContent(script.name, value: "\(script.interpreter) · actions/\(script.id)/\(script.entrypoint)")
            .font(.callout)
        }
        if !review.changes.isEmpty {
          Text("\(review.changes.count) file change(s). Previous approval does not cover this version.")
            .foregroundStyle(.secondary)
        }
        HSplitView {
          List(review.filePaths, id: \.self) { path in
            Button {
              store.send(.reviewFileSelected(path))
            } label: {
              HStack {
                Text(path).fontWeight(path == review.selectedFile ? .semibold : .regular)
                Spacer()
                if let change = review.changes.first(where: { $0.path == path }) {
                  Text(change.kind.rawValue).foregroundStyle(.secondary)
                }
              }
            }
            .buttonStyle(.plain)
            .help("Review \(path)")
          }
          .frame(minWidth: 180, idealWidth: 220)
          ScrollView([.horizontal, .vertical]) {
            Text(review.preview).font(.body.monospaced()).textSelection(.enabled)
              .frame(maxWidth: .infinity, alignment: .topLeading).padding(8)
          }
          .frame(minWidth: 340)
        }
        .frame(minHeight: 260)
        if let error = review.error { Text(error).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true) }
        if review.approved {
          Label("Approved. Start the workflow when you are ready.", systemImage: "checkmark.shield")
        }
        HStack {
          Button("Reveal Bundle") { store.send(.revealInFinderTapped) }
            .help("Open the bundle location in Finder")
          Spacer()
          Button("Close") { store.send(.dismissBundleReview) }.keyboardShortcut(.cancelAction)
            .help("Close this review (Escape)")
          if !review.approved {
            Button("Approve This Version") { store.send(.approveBundleTapped) }
              .buttonStyle(.borderedProminent)
              .disabled(review.scripts.isEmpty)
              .help("Approve this source and content version; this does not start the workflow")
          }
        }
      }
      .padding(24)
      .frame(minWidth: 720, idealWidth: 820, minHeight: 520)
      .accessibilityIdentifier("workflow-bundle-review")
    }
  }
}

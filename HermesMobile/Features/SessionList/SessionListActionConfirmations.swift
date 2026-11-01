import SwiftUI

/// A session list's delete confirmations, and its failed actions shown as failure toasts in
/// `actionToast` rather than alerts (#1410), since nothing needs the user's answer.
struct SessionActionConfirmations: ViewModifier {
    @Bindable var viewModel: SessionListViewModel
    let actionToast: ActionToastState
    @Binding var sessionPendingDeletion: SessionSummary?
    @Binding var projectPendingDeletion: ProjectSummary?

    let deleteSession: (SessionSummary) -> Void
    let deleteProject: (ProjectSummary) -> Void

    func body(content: Content) -> some View {
        content
            .onChange(of: viewModel.actionErrorMessage) { _, message in
                guard let message else { return }
                actionToast.show(.failure(message))
                viewModel.clearActionError()
            }
            .alert(
                "Delete Session?",
                isPresented: Binding(
                    get: { sessionPendingDeletion != nil },
                    set: { isPresented in
                        if !isPresented {
                            sessionPendingDeletion = nil
                        }
                    }
                )
            ) {
                Button("Cancel", role: .cancel) {
                    sessionPendingDeletion = nil
                }

                Button("Delete", role: .destructive) {
                    let session = sessionPendingDeletion
                    sessionPendingDeletion = nil

                    if let session {
                        deleteSession(session)
                    }
                }
            } message: {
                if sessionPendingDeletion?.hermes != nil {
                    Text("This deletes the session and its messages from the Hermes host. It can't be undone.")
                } else {
                    Text("This removes the session from the Hermes server. Use this only on a session you no longer need.")
                }
            }
            .alert(
                "Delete Project?",
                isPresented: Binding(
                    get: { projectPendingDeletion != nil },
                    set: { isPresented in
                        if !isPresented {
                            projectPendingDeletion = nil
                        }
                    }
                )
            ) {
                Button("Cancel", role: .cancel) {
                    projectPendingDeletion = nil
                }

                Button("Delete", role: .destructive) {
                    let project = projectPendingDeletion
                    projectPendingDeletion = nil

                    if let project {
                        deleteProject(project)
                    }
                }
            } message: {
                if projectPendingDeletion?.hermes != nil {
                    Text("Sessions stay; only the project is removed.")
                } else {
                    Text("Sessions in this project will be moved to No project. The sessions themselves will not be deleted.")
                }
            }
    }
}

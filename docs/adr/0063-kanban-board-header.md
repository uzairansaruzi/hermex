# 0063. Kanban Board header

Area: kanban

## Cap the Board picker's width in its own principal slot

The navigation bar drops the `.principal` slot outright when its content insists on a width that will not fit beside the bar's other items: the original #340 bug, where a long Board name took the picker off screen. A custom principal item is not constrained by its siblings on iOS 26 either; given `.frame(maxWidth: .infinity)` it spans the whole bar and draws under the back button and the trailing controls. Handing the title to the system (`.navigationTitle` + `.toolbarTitleMenu`) makes UIKit collapse New Card and Dispatcher into a system overflow button, hiding the Dispatcher's state icon. So `KanbanLabView` keeps the picker in its own slot with an explicit width cap from `KanbanHeaderPresentation.boardPickerMaxWidth` that can never exceed the real gap, and the name truncates inside it.

Lives in: `HermesMobile/Features/Kanban/KanbanLabView.swift`

# Hermex Domain

Canonical language for Hermex concepts that need consistent names across the product, planning, and support.

## Kanban

**Kanban**:
The Hermex destination for organizing and operating server-backed work across workflow states.
_Avoid_: Boards, Tasks

**Board**:
A named container of Kanban work and its workflow states.
_Avoid_: Kanban, project

**Card**:
An individual unit of work on a Board.
_Avoid_: Task, Kanban task, work item

**Status**:
The workflow state of a Card: Triage, To Do, Ready, Running, Blocked, Done, or Archived.
_Avoid_: Column, lane, stage

**Column**:
A visual grouping of Cards that share a Status.
_Avoid_: Status, lane

**Lane**:
An optional visual grouping of Cards by Profile, including an Unassigned lane.
_Avoid_: Status, column

**Profile**:
A Hermes agent configuration that can perform Card work.
_Avoid_: Assignee, user, agent

**Assignment**:
The relationship between a Card and the Profile selected to perform it. A Card without that relationship is Unassigned.
_Avoid_: Ownership

**Prerequisite**:
A Card that must precede another Card in a dependency relationship.
_Avoid_: Parent, blocker

**Dependent**:
A Card that relies on a Prerequisite.
_Avoid_: Child, blocked card

**Dispatcher**:
The server operation that claims eligible Ready Cards and may launch worker processes.
_Avoid_: Runner, launcher

**Preview Dispatch**:
A dry run that reports expected Dispatcher outcomes without launching workers.
_Avoid_: Test run, simulate dispatcher

**Run Dispatcher**:
The action that invokes the Dispatcher and may launch workers or consume API budget.
_Avoid_: Dispatch, run

**Dispatch Run**:
The recorded execution of the Dispatcher.
_Avoid_: Run, dispatcher result

**Archived**:
The Status of a Card removed from the active workflow.
_Avoid_: Deleted

**Archive Card**:
The action that changes a Card's Status to Archived.
_Avoid_: Delete Card, remove Card

**Archive Board**:
The action that removes a non-default Board from active use. Hermex cannot restore an archived Board in-app.
_Avoid_: Delete Board, remove Board

**Bulk Action**:
A named operation applied to multiple selected Cards.
_Avoid_: Bulk update, batch operation

**Select Cards**:
The mode for choosing Cards before applying a Bulk Action.
_Avoid_: Multi-select, bulk mode

import Foundation
public protocol WatchCompanionServicing:Sendable{
 func registry()async->RegistrySnapshot
 func refreshSessions(scope:ServerScope,collection:SessionCollection,query:String?,localLimit:Int)async throws->ScopedSnapshot<BoundedCollection<WatchSessionSummary>>
 func composerOptions(scope:ServerScope)async throws->ScopedSnapshot<WatchComposerOptions>
 func switchActiveProfile(scope:ServerScope,name:String,expectedRevision:Revision)async throws->String
 func transcript(key:SessionKey,before:Int?,limit:Int)async throws->ScopedSnapshot<WatchTranscript>
 func createSession(scope:ServerScope,profileID:ProfileID?,workspaceHandle:WorkspaceHandle?,context:CommandContext)async->CommandReceipt<SessionKey>
 func send(text:String,to key:SessionKey,context:CommandContext)async->CommandReceipt<RunKey>
 func events(for run:RunKey,afterEventID:String?)->AsyncThrowingStream<WatchRunEvent,Error>
 func reconcile(run:RunKey)async throws->ScopedSnapshot<WatchRunState>
 func stop(run:RunKey,context:CommandContext)async->CommandReceipt<EmptyValue>
 func pendingApprovalHead(session:SessionKey)async throws->ScopedSnapshot<WatchAttentionHead<WatchApproval>>
 func pendingClarificationHead(session:SessionKey)async throws->ScopedSnapshot<WatchAttentionHead<WatchClarification>>
 func respond(approval:ApprovalKey,choice:ApprovalChoice,context:CommandContext)async->CommandReceipt<EmptyValue>
 func respond(clarification:ClarificationKey,answer:String,context:CommandContext)async->CommandReceipt<EmptyValue>
 func tasks(scope:ServerScope,localLimit:Int)async throws->ScopedSnapshot<BoundedCollection<WatchTaskSummary>>
 func taskRuns(key:TaskKey,page:PageRequest)async throws->ScopedSnapshot<BoundedPage<WatchTaskRun>>
 func taskRunDetail(key:TaskKey,runID:String)async throws->ScopedSnapshot<WatchTaskRunDetail>
 func controlTask(key:TaskKey,action:TaskControl,context:CommandContext)async->CommandReceipt<EmptyValue>
 func skills(scope:ServerScope,query:String?,localLimit:Int)async throws->ScopedSnapshot<BoundedCollection<WatchSkillSummary>>
 func skillDetail(key:SkillKey)async throws->ScopedSnapshot<WatchSkillDetail>
 func skillContent(key:SkillKey,fileHandle:PathHandle?)async throws->ScopedSnapshot<WatchSkillContent>
 func memoryDocument(scope:ServerScope)async throws->ScopedSnapshot<WatchMemoryDocument>
 func insightsAggregate(scope:ServerScope,days:InsightsDays)async throws->ScopedSnapshot<WatchInsightsAggregate>
 func workspace(session:SessionKey,parentPathHandle:PathHandle?)async throws->ScopedSnapshot<BoundedCollection<WatchWorkspaceEntry>>
 func filePreview(session:SessionKey,pathHandle:PathHandle)async throws->ScopedSnapshot<WatchFilePreview>
 func gitAggregate(session:SessionKey)async throws->ScopedSnapshot<WatchGitAggregate>
 func diagnostics(scope:ServerScope)async throws->ScopedSnapshot<WatchDiagnosticsProjection>
 func media(_ descriptor:WatchMediaDescriptor)async throws->WatchMediaPayload
 func bots(scope:ServerScope)async throws->ScopedSnapshot<[WatchBotSummary]>
 func botConversation(key:BotKey)async throws->ScopedSnapshot<WatchBotConversation>
 func botEvents(for key:BotKey,replayEpoch:String?,afterSequence:Int?)->AsyncThrowingStream<WatchBotEvent,Error>
 func sendBot(text:String,to key:BotKey,context:CommandContext)async->CommandReceipt<EmptyValue>
 func interruptBot(key:BotKey,context:CommandContext)async->CommandReceipt<EmptyValue>
 func setSkillEnabled(scope:ServerScope,name:String,enabled:Bool,expectedRevision:Revision)async throws
 func moveKanbanCard(scope:ServerScope,cardID:String,status:String,boardSlug:String,expectedRevision:Revision)async throws
 func createKanbanCard(scope:ServerScope,boardSlug:String,title:String,status:String,expectedRevision:Revision)async throws
 func dispatchKanban(scope:ServerScope,boardSlug:String,dryRun:Bool,expectedRevision:Revision)async throws->String
}

public extension WatchCompanionServicing {
 func switchActiveProfile(scope:ServerScope,name:String,expectedRevision:Revision)async throws->String{throw WatchCompanionError.unsupported(.composerOptions)}
 func setSkillEnabled(scope:ServerScope,name:String,enabled:Bool,expectedRevision:Revision)async throws{throw WatchCompanionError.unsupported(.skills)}
 func moveKanbanCard(scope:ServerScope,cardID:String,status:String,boardSlug:String,expectedRevision:Revision)async throws{throw WatchCompanionError.unsupported(.tasks)}
 func createKanbanCard(scope:ServerScope,boardSlug:String,title:String,status:String,expectedRevision:Revision)async throws{throw WatchCompanionError.unsupported(.tasks)}
 func dispatchKanban(scope:ServerScope,boardSlug:String,dryRun:Bool,expectedRevision:Revision)async throws->String{throw WatchCompanionError.unsupported(.tasks)}
 func respond(approval:ApprovalKey,choice:ApprovalChoice,context:CommandContext)async->CommandReceipt<EmptyValue>{currentPinAttentionRejection(context:context,operationKind:.respondApproval)}
 func respond(clarification:ClarificationKey,answer:String,context:CommandContext)async->CommandReceipt<EmptyValue>{currentPinAttentionRejection(context:context,operationKind:.respondClarification)}
 private func currentPinAttentionRejection(context:CommandContext,operationKind:WatchOperationKind)->CommandReceipt<EmptyValue>{
  let receipt=try! MutationReceipt(context:context,operationKind:operationKind,phase:.rejected,updatedAt:context.createdAt,nonSecretResultID:"attentionExactIDUnavailable")
  return CommandReceipt(receipt:receipt,value:nil)
 }
}

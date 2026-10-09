import Foundation

extension ScopedSnapshot: Equatable where Value: Equatable {
 public static func ==(lhs:Self,rhs:Self)->Bool{lhs.schema==rhs.schema&&lhs.scope==rhs.scope&&lhs.revision==rhs.revision&&lhs.freshness==rhs.freshness&&lhs.value==rhs.value}
}
extension ScopedSnapshot: Hashable where Value: Hashable {
 public func hash(into hasher:inout Hasher){hasher.combine(schema);hasher.combine(scope);hasher.combine(revision);hasher.combine(freshness);hasher.combine(value)}
}

public enum WatchOperationResult:Hashable,Codable,Sendable{
 case sessions(ScopedSnapshot<BoundedCollection<WatchSessionSummary>>);case composerOptions(ScopedSnapshot<WatchComposerOptions>);case transcript(ScopedSnapshot<WatchTranscript>);case runState(ScopedSnapshot<WatchRunState>);case pendingApprovalHead(ScopedSnapshot<WatchAttentionHead<WatchApproval>>);case pendingClarificationHead(ScopedSnapshot<WatchAttentionHead<WatchClarification>>);case tasks(ScopedSnapshot<BoundedCollection<WatchTaskSummary>>);case taskRuns(ScopedSnapshot<BoundedPage<WatchTaskRun>>);case taskRunDetail(ScopedSnapshot<WatchTaskRunDetail>);case skills(ScopedSnapshot<BoundedCollection<WatchSkillSummary>>);case skillDetail(ScopedSnapshot<WatchSkillDetail>);case skillContent(ScopedSnapshot<WatchSkillContent>);case memoryDocument(ScopedSnapshot<WatchMemoryDocument>);case insightsAggregate(ScopedSnapshot<WatchInsightsAggregate>);case workspace(ScopedSnapshot<BoundedCollection<WatchWorkspaceEntry>>);case filePreview(ScopedSnapshot<WatchFilePreview>);case gitAggregate(ScopedSnapshot<WatchGitAggregate>);case diagnostics(ScopedSnapshot<WatchDiagnosticsProjection>);case media(WatchMediaPayload);case bots(ScopedSnapshot<[WatchBotSummary]>);case botConversation(ScopedSnapshot<WatchBotConversation>);case createdSession(CommandReceipt<SessionKey>);case startedRun(CommandReceipt<RunKey>);case mutation(CommandReceipt<EmptyValue>);case runEvent(WatchRunEvent);case botEvent(WatchBotEvent);case failure(WatchTransportFailure)
 public var kind:WatchOperationKind?{switch self{case .sessions:return.sessions;case .composerOptions:return.composerOptions;case .transcript:return.transcript;case .runState:return.runState;case .pendingApprovalHead:return.pendingApprovalHead;case .pendingClarificationHead:return.pendingClarificationHead;case .tasks:return.tasks;case .taskRuns:return.taskRuns;case .taskRunDetail:return.taskRunDetail;case .skills:return.skills;case .skillDetail:return.skillDetail;case .skillContent:return.skillContent;case .memoryDocument:return.memoryDocument;case .insightsAggregate:return.insightsAggregate;case .workspace:return.workspace;case .filePreview:return.filePreview;case .gitAggregate:return.gitAggregate;case .diagnostics:return.diagnostics;case .media:return.media;case .bots:return.bots;case .botConversation:return.botConversation;case .createdSession:return.createSession;case .startedRun:return.send;case .mutation(let r):return r.receipt.operationKind;case .runEvent:return.runStream;case .botEvent:return.botStream;case .failure:return nil}}
 public var scope:ServerScope?{switch self{case .sessions(let v):return v.scope;case .composerOptions(let v):return v.scope;case .transcript(let v):return v.scope;case .runState(let v):return v.scope;case .pendingApprovalHead(let v):return v.scope;case .pendingClarificationHead(let v):return v.scope;case .tasks(let v):return v.scope;case .taskRuns(let v):return v.scope;case .taskRunDetail(let v):return v.scope;case .skills(let v):return v.scope;case .skillDetail(let v):return v.scope;case .skillContent(let v):return v.scope;case .memoryDocument(let v):return v.scope;case .insightsAggregate(let v):return v.scope;case .workspace(let v):return v.scope;case .filePreview(let v):return v.scope;case .gitAggregate(let v):return v.scope;case .diagnostics(let v):return v.scope;case .media(let v):return v.descriptor.scope;case .bots(let v):return v.scope;case .botConversation(let v):return v.scope;case .createdSession(let v):return v.receipt.context.scope;case .startedRun(let v):return v.receipt.context.scope;case .mutation(let v):return v.receipt.context.scope;case .runEvent(let v):return v.key.session.scope;case .botEvent(let v):return v.key.scope;case .failure:return nil}}
 public var receipt:MutationReceipt?{switch self{case .createdSession(let v):return v.receipt;case .startedRun(let v):return v.receipt;case .mutation(let v):return v.receipt;default:return nil}}
 func validate()throws{
  func same(_ actual:ServerScope,_ expected:ServerScope)throws{guard actual==expected else{throw EnvelopeValidationError.scopeMismatch}}
  func blocks(_ values:[WatchTranscriptBlock],_ scope:ServerScope)throws{for block in values{if case .image(_,let descriptor,_)=block{try same(descriptor.scope,scope)}}}
  switch self{
  case .sessions(let v):guard v.value.items.count<=100 else{throw EnvelopeValidationError.resultMismatch};for x in v.value.items{try same(x.key.scope,v.scope)}
  case .composerOptions(let v):try same(v.value.scope,v.scope)
  case .transcript(let v):try same(v.value.session.scope,v.scope);try blocks(v.value.blocks,v.scope)
  case .runState(let v):try same(v.value.key.session.scope,v.scope)
  case .pendingApprovalHead(let v):if let x=v.value.item{try same(x.key.session.scope,v.scope)}
  case .pendingClarificationHead(let v):if let x=v.value.item{try same(x.key.session.scope,v.scope)}
  case .tasks(let v):guard v.value.items.count<=64 else{throw EnvelopeValidationError.resultMismatch};for x in v.value.items{try same(x.key.scope,v.scope)}
  case .taskRuns(let v):guard v.value.items.count<=50 else{throw EnvelopeValidationError.resultMismatch};for x in v.value.items{try same(x.task.scope,v.scope)}
  case .taskRunDetail(let v):try same(v.value.run.task.scope,v.scope)
  case .skills(let v):guard v.value.items.count<=128 else{throw EnvelopeValidationError.resultMismatch};for x in v.value.items{try same(x.key.scope,v.scope)}
  case .skillDetail(let v):try same(v.value.key.scope,v.scope)
  case .skillContent(let v):try same(v.value.key.scope,v.scope)
  case .memoryDocument(let v):for x in v.value.sections{try same(x.key.scope,v.scope)}
  case .insightsAggregate:break
  case .workspace(let v):guard v.value.items.count<=200 else{throw EnvelopeValidationError.resultMismatch};for x in v.value.items{try same(x.session.scope,v.scope)}
  case .filePreview(let v):if case .image(_,let media)=v.value{try same(media.scope,v.scope)}
  case .gitAggregate(let v):try same(v.value.session.scope,v.scope)
  case .diagnostics(let v):try same(v.value.scope,v.scope)
  case .media:break
  case .bots(let v):guard v.value.count<=128 else{throw EnvelopeValidationError.resultMismatch};for x in v.value{try same(x.key.scope,v.scope)}
  case .botConversation(let v):try same(v.value.key.scope,v.scope);try blocks(v.value.blocks,v.scope)
  case .createdSession(let v):guard v.receipt.operationKind == .createSession else{throw EnvelopeValidationError.resultMismatch};if let x=v.value{try same(x.scope,v.receipt.context.scope)}
  case .startedRun(let v):guard v.receipt.operationKind == .send else{throw EnvelopeValidationError.resultMismatch};if let x=v.value{try same(x.session.scope,v.receipt.context.scope)}
  case .mutation(let v):guard [.stop,.respondApproval,.respondClarification,.controlTask,.sendBot,.interruptBot].contains(v.receipt.operationKind)else{throw EnvelopeValidationError.resultMismatch}
  case .runEvent,.botEvent,.failure:break
  }
 }
 func validate(against operation:WatchReadOperation)throws{
  if case .failure=self{return}
  let matches:Bool
  switch(operation,self){
  case(.sessions,.sessions),(.composerOptions,.composerOptions),(.tasks,.tasks),(.skills,.skills),(.memoryDocument,.memoryDocument),(.insightsAggregate,.insightsAggregate),(.diagnostics,.diagnostics),(.bots,.bots):matches=true
  case(.transcript(let session,_,_),.transcript(let v)):matches=v.value.session==session
  case(.runState(let run),.runState(let v)):matches=v.value.key==run
  case(.pendingApprovalHead(let session),.pendingApprovalHead(let v)):matches=v.value.item.map{$0.key.session==session} ?? true
  case(.pendingClarificationHead(let session),.pendingClarificationHead(let v)):matches=v.value.item.map{$0.key.session==session} ?? true
  case(.taskRuns(let task,_),.taskRuns(let v)):matches=v.value.items.allSatisfy{$0.task==task}
  case(.taskRunDetail(let task,let runID),.taskRunDetail(let v)):matches=v.value.run.task==task&&v.value.run.runID==runID
  case(.skillDetail(let skill),.skillDetail(let v)):matches=v.value.key==skill
  case(.skillContent(let skill,let fileHandle),.skillContent(let v)):matches=v.value.key==skill&&v.value.fileHandle==fileHandle
  case(.workspace(let session,_),.workspace(let v)):matches=v.value.items.allSatisfy{$0.session==session}
  case(.filePreview(let session,let pathHandle),.filePreview(let v)):
   switch v.value{case .text(let returned,_,_),.unsupported(let returned,_):matches=returned==pathHandle;case .image(let returned,let media):matches=returned==pathHandle&&media.session==session}
  case(.gitAggregate(let session),.gitAggregate(let v)):matches=v.value.session==session
  case(.media(let descriptor),.media(let v)):matches=v.descriptor==descriptor
  case(.botConversation(let bot),.botConversation(let v)):matches=v.value.key==bot
  default:matches=false
  }
  guard matches else{throw EnvelopeValidationError.resultMismatch}
 }
 func validate(against operation:WatchStreamOperation)throws{
  if case .failure=self{return}
  let matches:Bool
  switch(operation,self){case(.run(let run,_),.runEvent(let event)):matches=event.key==run;case(.bot(let bot,_,_),.botEvent(let event)):matches=event.key==bot;default:matches=false}
  guard matches else{throw EnvelopeValidationError.resultMismatch}
 }
 func validate(against operation:WatchMutationOperation)throws{
  if case .failure=self{return}
  let matches:Bool
  switch(operation,self){
  case(.createSession(let scope,_,_),.createdSession(let receipt)):matches=receipt.value.map{$0.scope==scope} ?? true
  case(.send(let session,_),.startedRun(let receipt)):matches=receipt.value.map{$0.session==session} ?? true
  case(.stop,.mutation),(.controlTask,.mutation),(.sendBot,.mutation),(.interruptBot,.mutation):matches=true
  default:matches=false
  }
  guard matches else{throw EnvelopeValidationError.resultMismatch}
 }
 public init(from decoder:Decoder)throws{let value=try WatchOperationResultWire(from:decoder).value;try value.validate();self=value}
}

private enum WatchOperationResultWire:Hashable,Codable{case sessions(ScopedSnapshot<BoundedCollection<WatchSessionSummary>>);case composerOptions(ScopedSnapshot<WatchComposerOptions>);case transcript(ScopedSnapshot<WatchTranscript>);case runState(ScopedSnapshot<WatchRunState>);case pendingApprovalHead(ScopedSnapshot<WatchAttentionHead<WatchApproval>>);case pendingClarificationHead(ScopedSnapshot<WatchAttentionHead<WatchClarification>>);case tasks(ScopedSnapshot<BoundedCollection<WatchTaskSummary>>);case taskRuns(ScopedSnapshot<BoundedPage<WatchTaskRun>>);case taskRunDetail(ScopedSnapshot<WatchTaskRunDetail>);case skills(ScopedSnapshot<BoundedCollection<WatchSkillSummary>>);case skillDetail(ScopedSnapshot<WatchSkillDetail>);case skillContent(ScopedSnapshot<WatchSkillContent>);case memoryDocument(ScopedSnapshot<WatchMemoryDocument>);case insightsAggregate(ScopedSnapshot<WatchInsightsAggregate>);case workspace(ScopedSnapshot<BoundedCollection<WatchWorkspaceEntry>>);case filePreview(ScopedSnapshot<WatchFilePreview>);case gitAggregate(ScopedSnapshot<WatchGitAggregate>);case diagnostics(ScopedSnapshot<WatchDiagnosticsProjection>);case media(WatchMediaPayload);case bots(ScopedSnapshot<[WatchBotSummary]>);case botConversation(ScopedSnapshot<WatchBotConversation>);case createdSession(CommandReceipt<SessionKey>);case startedRun(CommandReceipt<RunKey>);case mutation(CommandReceipt<EmptyValue>);case runEvent(WatchRunEvent);case botEvent(WatchBotEvent);case failure(WatchTransportFailure);var value:WatchOperationResult{switch self{case .sessions(let x):return.sessions(x);case .composerOptions(let x):return.composerOptions(x);case .transcript(let x):return.transcript(x);case .runState(let x):return.runState(x);case .pendingApprovalHead(let x):return.pendingApprovalHead(x);case .pendingClarificationHead(let x):return.pendingClarificationHead(x);case .tasks(let x):return.tasks(x);case .taskRuns(let x):return.taskRuns(x);case .taskRunDetail(let x):return.taskRunDetail(x);case .skills(let x):return.skills(x);case .skillDetail(let x):return.skillDetail(x);case .skillContent(let x):return.skillContent(x);case .memoryDocument(let x):return.memoryDocument(x);case .insightsAggregate(let x):return.insightsAggregate(x);case .workspace(let x):return.workspace(x);case .filePreview(let x):return.filePreview(x);case .gitAggregate(let x):return.gitAggregate(x);case .diagnostics(let x):return.diagnostics(x);case .media(let x):return.media(x);case .bots(let x):return.bots(x);case .botConversation(let x):return.botConversation(x);case .createdSession(let x):return.createdSession(x);case .startedRun(let x):return.startedRun(x);case .mutation(let x):return.mutation(x);case .runEvent(let x):return.runEvent(x);case .botEvent(let x):return.botEvent(x);case .failure(let x):return.failure(x)}}}

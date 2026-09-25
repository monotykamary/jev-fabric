export type Json = null | boolean | number | string | Json[] | { [key: string]: Json };
export type Description = string | Json[] | { [key: string]: Json };
export type Question =
  | { type: 'choice'; instructions: Description; criteria: Record<string, Description | null> }
  | { type: 'noul'; instructions: Description; criteria?: { true?: Description; false?: Description } }
  | { type: 'score'; instructions: Description; criteria: Description[] };
export type ChoiceAnswer = {
  type: 'choice';
  choice: string;
  confidence: number;
  probabilities: Record<string, number>;
};
export type NoulAnswer = { type: 'noul'; noul: number };
export type ScoreAnswer = {
  type: 'score';
  score: number;
  confidence: number;
  probabilities: Record<string, number>;
  legend: Record<string, Json>;
};
export type Answer = ChoiceAnswer | NoulAnswer | ScoreAnswer;
export type AnswerFor<Q> =
  Q extends { type: 'choice' } ? ChoiceAnswer
  : Q extends { type: 'noul' } ? NoulAnswer
  : Q extends { type: 'score' } ? ScoreAnswer
  : Answer;
export interface JevRequest<Q extends Record<string, Question> = Record<string, Question>> {
  state: Description;
  questions: Q;
  model?: string;
}
export interface JevResponse<Q extends Record<string, Question> = Record<string, Question>> {
  model: string;
  answers: { [K in keyof Q]: AnswerFor<Q[K]> };
  usage: { input_tokens: number; output_tokens: number };
}
export interface FabricEvent { sequence: number; at: string; type: string; data: Json }
export type RunState = 'running' | 'completed' | 'needs_attention' | 'failed' | 'cancelled' | 'timed_out';
export interface RunRecord {
  schemaVersion: 1;
  id: string;
  program: string;
  state: RunState;
  startedAt: string;
  endedAt?: string;
  result?: Json;
  error?: string;
  evaluations: number;
  usage: { input_tokens: number; output_tokens: number };
}
export interface RunPlan {
  id: string;
  directory: string;
  program: string;
  cwd: string;
  input: Json;
  timeoutMs: number;
  maxEvaluations: number;
  maxTokens: number;
}

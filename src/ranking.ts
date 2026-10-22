export type ScoreEntry = { id: string; name: string; score: number; detail?: string }

export const scoreGroups = (entries: ScoreEntry[]) => [...new Set(entries.map(e => e.score))].sort((a,b) => a-b)
export const scoreRank = (entries: ScoreEntry[], score: number) => entries.filter(e => e.score > score).length + 1
export const visibleScores = (entries: ScoreEntry[], count: number) => {
  const groups = scoreGroups(entries).slice(0,count)
  return [...entries].filter(e => groups.includes(e.score)).sort((a,b) => a.score-b.score || b.id.localeCompare(a.id))
}

export type Prompt = { left: string; right: string; category: string }
// 元の200種類から厳選した100種類。左側が0、右側が100。
export const prompts: Prompt[] = [
  {
    "category": "日常・生活",
    "left": "冷たい",
    "right": "熱い"
  },
  {
    "category": "日常・生活",
    "left": "静か",
    "right": "うるさい"
  },
  {
    "category": "日常・生活",
    "left": "簡単",
    "right": "難しい"
  },
  {
    "category": "日常・生活",
    "left": "ありふれた",
    "right": "珍しい"
  },
  {
    "category": "日常・生活",
    "left": "便利じゃない",
    "right": "とても便利"
  },
  {
    "category": "日常・生活",
    "left": "散らかっている",
    "right": "片付いている"
  },
  {
    "category": "日常・生活",
    "left": "短く感じる",
    "right": "長く感じる"
  },
  {
    "category": "日常・生活",
    "left": "落ち着かない",
    "right": "落ち着く"
  },
  {
    "category": "日常・生活",
    "left": "時間がかかる",
    "right": "すぐ終わる"
  },
  {
    "category": "日常・生活",
    "left": "毎日は無理",
    "right": "毎日でもできる"
  },
  {
    "category": "日常・生活",
    "left": "お金がかからない",
    "right": "お金がかかる"
  },
  {
    "category": "日常・生活",
    "left": "一人向き",
    "right": "大人数向き"
  },
  {
    "category": "日常・生活",
    "left": "屋内向き",
    "right": "屋外向き"
  },
  {
    "category": "日常・生活",
    "left": "冬向き",
    "right": "夏向き"
  },
  {
    "category": "日常・生活",
    "left": "眠くなる",
    "right": "目が覚める"
  },
  {
    "category": "日常・生活",
    "left": "気軽にできる",
    "right": "覚悟が必要"
  },
  {
    "category": "食べ物・飲み物",
    "left": "甘くない",
    "right": "とても甘い"
  },
  {
    "category": "食べ物・飲み物",
    "left": "辛くない",
    "right": "激辛"
  },
  {
    "category": "食べ物・飲み物",
    "left": "薄味",
    "right": "濃い味"
  },
  {
    "category": "食べ物・飲み物",
    "left": "さっぱり",
    "right": "こってり"
  },
  {
    "category": "食べ物・飲み物",
    "left": "軽食向き",
    "right": "がっつり食事向き"
  },
  {
    "category": "食べ物・飲み物",
    "left": "朝食向き",
    "right": "夕食向き"
  },
  {
    "category": "食べ物・飲み物",
    "left": "健康的",
    "right": "不健康"
  },
  {
    "category": "食べ物・飲み物",
    "left": "見た目が地味",
    "right": "見た目が華やか"
  },
  {
    "category": "食べ物・飲み物",
    "left": "安い",
    "right": "高い"
  },
  {
    "category": "食べ物・飲み物",
    "left": "食べやすい",
    "right": "食べにくい"
  },
  {
    "category": "食べ物・飲み物",
    "left": "子ども向け",
    "right": "大人向け"
  },
  {
    "category": "食べ物・飲み物",
    "left": "万人受けしない",
    "right": "万人受けする"
  },
  {
    "category": "食べ物・飲み物",
    "left": "手軽に作れる",
    "right": "調理が大変"
  },
  {
    "category": "食べ物・飲み物",
    "left": "冷やしたい",
    "right": "熱々で食べたい"
  },
  {
    "category": "食べ物・飲み物",
    "left": "香りが弱い",
    "right": "香りが強い"
  },
  {
    "category": "食べ物・飲み物",
    "left": "食感が柔らかい",
    "right": "食感が硬い"
  },
  {
    "category": "人柄・価値観",
    "left": "子どもっぽい",
    "right": "大人っぽい"
  },
  {
    "category": "人柄・価値観",
    "left": "地味",
    "right": "派手"
  },
  {
    "category": "人柄・価値観",
    "left": "慎重",
    "right": "大胆"
  },
  {
    "category": "人柄・価値観",
    "left": "人見知り",
    "right": "社交的"
  },
  {
    "category": "人柄・価値観",
    "left": "マイペース",
    "right": "せっかち"
  },
  {
    "category": "人柄・価値観",
    "left": "現実的",
    "right": "夢見がち"
  },
  {
    "category": "人柄・価値観",
    "left": "優柔不断",
    "right": "決断が早い"
  },
  {
    "category": "人柄・価値観",
    "left": "温厚",
    "right": "短気"
  },
  {
    "category": "人柄・価値観",
    "left": "感情が顔に出ない",
    "right": "感情が顔に出る"
  },
  {
    "category": "人柄・価値観",
    "left": "計画的",
    "right": "行き当たりばったり"
  },
  {
    "category": "人柄・価値観",
    "left": "論理的",
    "right": "感覚的"
  },
  {
    "category": "人柄・価値観",
    "left": "クール",
    "right": "情熱的"
  },
  {
    "category": "人柄・価値観",
    "left": "自分に厳しい",
    "right": "自分に甘い"
  },
  {
    "category": "人柄・価値観",
    "left": "信用できない",
    "right": "信用できる"
  },
  {
    "category": "遊び・ゲーム",
    "left": "運要素が強い",
    "right": "実力要素が強い"
  },
  {
    "category": "遊び・ゲーム",
    "left": "初心者向け",
    "right": "上級者向け"
  },
  {
    "category": "遊び・ゲーム",
    "left": "短時間で遊べる",
    "right": "長時間遊べる"
  },
  {
    "category": "遊び・ゲーム",
    "left": "協力向き",
    "right": "対戦向き"
  },
  {
    "category": "遊び・ゲーム",
    "left": "操作が簡単",
    "right": "操作が複雑"
  },
  {
    "category": "遊び・ゲーム",
    "left": "怖くない",
    "right": "めちゃくちゃ怖い"
  },
  {
    "category": "遊び・ゲーム",
    "left": "何も考えず遊べる",
    "right": "頭を使う"
  },
  {
    "category": "遊び・ゲーム",
    "left": "自由度が低い",
    "right": "自由度が高い"
  },
  {
    "category": "遊び・ゲーム",
    "left": "テンポが遅い",
    "right": "テンポが速い"
  },
  {
    "category": "遊び・ゲーム",
    "left": "平和",
    "right": "殺伐"
  },
  {
    "category": "学校・仕事",
    "left": "準備が不要",
    "right": "準備が大変"
  },
  {
    "category": "学校・仕事",
    "left": "暗記が重要",
    "right": "ひらめきが重要"
  },
  {
    "category": "学校・仕事",
    "left": "初心者でもできる",
    "right": "専門知識が必要"
  },
  {
    "category": "学校・仕事",
    "left": "失敗しても平気",
    "right": "失敗できない"
  },
  {
    "category": "学校・仕事",
    "left": "リモート向き",
    "right": "対面向き"
  },
  {
    "category": "学校・仕事",
    "left": "ルーティン",
    "right": "毎回違う"
  },
  {
    "category": "学校・仕事",
    "left": "目立たない仕事",
    "right": "目立つ仕事"
  },
  {
    "category": "学校・仕事",
    "left": "自由な服装向き",
    "right": "フォーマル向き"
  },
  {
    "category": "旅行・おでかけ",
    "left": "日帰り向き",
    "right": "宿泊向き"
  },
  {
    "category": "旅行・おでかけ",
    "left": "観光客が少ない",
    "right": "観光客が多い"
  },
  {
    "category": "旅行・おでかけ",
    "left": "写真映えしない",
    "right": "写真映えする"
  },
  {
    "category": "旅行・おでかけ",
    "left": "計画なしで行ける",
    "right": "綿密な計画が必要"
  },
  {
    "category": "旅行・おでかけ",
    "left": "都会的",
    "right": "自然豊か"
  },
  {
    "category": "旅行・おでかけ",
    "left": "雨でも楽しめる",
    "right": "晴れじゃないと厳しい"
  },
  {
    "category": "旅行・おでかけ",
    "left": "朝が楽しい",
    "right": "夜が楽しい"
  },
  {
    "category": "旅行・おでかけ",
    "left": "歩かなくていい",
    "right": "たくさん歩く"
  },
  {
    "category": "エンタメ・創作",
    "left": "ダサい",
    "right": "おしゃれ"
  },
  {
    "category": "エンタメ・創作",
    "left": "ありがち",
    "right": "斬新"
  },
  {
    "category": "エンタメ・創作",
    "left": "予想通り",
    "right": "予想外"
  },
  {
    "category": "エンタメ・創作",
    "left": "明るい雰囲気",
    "right": "暗い雰囲気"
  },
  {
    "category": "エンタメ・創作",
    "left": "現実的",
    "right": "ファンタジー"
  },
  {
    "category": "エンタメ・創作",
    "left": "わかりやすい",
    "right": "解釈が難しい"
  },
  {
    "category": "エンタメ・創作",
    "left": "何も残らない",
    "right": "余韻が強い"
  },
  {
    "category": "エンタメ・創作",
    "left": "小規模な作品",
    "right": "超大作"
  },
  {
    "category": "エンタメ・創作",
    "left": "知名度が低い",
    "right": "知名度が高い"
  },
  {
    "category": "恋愛・友情",
    "left": "距離感が遠い",
    "right": "距離感が近い"
  },
  {
    "category": "恋愛・友情",
    "left": "さりげない好意",
    "right": "わかりやすい好意"
  },
  {
    "category": "恋愛・友情",
    "left": "連絡が少ない",
    "right": "連絡が多い"
  },
  {
    "category": "恋愛・友情",
    "left": "関係が浅い",
    "right": "関係が深い"
  },
  {
    "category": "恋愛・友情",
    "left": "束縛しない",
    "right": "束縛が強い"
  },
  {
    "category": "恋愛・友情",
    "left": "思い出に残らない",
    "right": "一生の思い出"
  },
  {
    "category": "もしも・想像",
    "left": "現実に起こりそう",
    "right": "絶対に起こらなそう"
  },
  {
    "category": "もしも・想像",
    "left": "欲しくない能力",
    "right": "欲しい能力"
  },
  {
    "category": "もしも・想像",
    "left": "小さな変化",
    "right": "世界が変わる変化"
  },
  {
    "category": "もしも・想像",
    "left": "リスクが低い",
    "right": "リスクが高い"
  },
  {
    "category": "もしも・想像",
    "left": "使い道が少ない",
    "right": "使い道が多い"
  },
  {
    "category": "ネタ・盛り上がり",
    "left": "安っぽい",
    "right": "高級感がある"
  },
  {
    "category": "ネタ・盛り上がり",
    "left": "許せる失敗",
    "right": "許せない失敗"
  },
  {
    "category": "ネタ・盛り上がり",
    "left": "ちょっと恥ずかしい",
    "right": "かなり恥ずかしい"
  },
  {
    "category": "ネタ・盛り上がり",
    "left": "弱そう",
    "right": "強そう"
  },
  {
    "category": "ネタ・盛り上がり",
    "left": "かわいくない",
    "right": "めちゃくちゃかわいい"
  },
  {
    "category": "ネタ・盛り上がり",
    "left": "面白くない",
    "right": "爆笑もの"
  },
  {
    "category": "ネタ・盛り上がり",
    "left": "日常の事件",
    "right": "大事件"
  },
  {
    "category": "ネタ・盛り上がり",
    "left": "普通の言い訳",
    "right": "苦しい言い訳"
  }
]

export const randomPrompt = (used: { left: string; right: string }[] = []): Prompt => {
  const available = prompts.filter(p => !used.some(u => u.left === p.left && u.right === p.right))
  const pool = available.length ? available : prompts
  return pool[Math.floor(Math.random() * pool.length)]
}

import SwiftUI
import SpriteKit
import Combine
import CoreData

// MARK: - Entry Point
@main
struct FocusCoreApp: App {
    let persistenceController = PersistenceController.shared
    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(\.managedObjectContext, persistenceController.container.viewContext)
                .preferredColorScheme(.dark)
        }
    }
}

// MARK: - CoreData Stack
class PersistenceController {
    static let shared = PersistenceController()
    let container: NSPersistentContainer
    init() {
        container = NSPersistentContainer(name: "FocusCore")
        let description = NSPersistentStoreDescription()
        description.type = NSInMemoryStoreType
        container.persistentStoreDescriptions = [description]
        container.loadPersistentStores { _, error in
            if let error = error { print("CoreData error: \(error)") }
        }
        container.viewContext.automaticallyMergesChangesFromParent = true
        createEntityDescriptions()
    }
    func createEntityDescriptions() {}
}

// MARK: - UserDefaults Keys
struct UDKeys {
    static let userName = "fc_userName"
    static let userPhotoData = "fc_userPhotoData"
    static let onboardingDone = "fc_onboardingDone"
    static let currentLevel = "fc_currentLevel"
    static let totalXP = "fc_totalXP"
    static let currentStreak = "fc_currentStreak"
    static let lastActiveDate = "fc_lastActiveDate"
    static let lessonsCompleted = "fc_lessonsCompleted"
    static let achievementsUnlocked = "fc_achievementsUnlocked"
    static let sessionHistory = "fc_sessionHistory"
    static let dailyLoginDone = "fc_dailyLoginDone"
    static let dailyLoginDate = "fc_dailyLoginDate"
    static let dailyGoalSessions = "fc_dailyGoalSessions"
    static let dailyGoalDate = "fc_dailyGoalDate"
    static let todaySessionCount = "fc_todaySessionCount"
}

// MARK: - App State (ViewModel)
class AppState: ObservableObject {
    static let shared = AppState()

    @Published var userName: String = ""
    @Published var userPhotoData: Data? = nil
    @Published var onboardingDone: Bool = false
    @Published var currentLevel: Int = 1
    @Published var totalXP: Int = 0
    @Published var currentStreak: Int = 0
    @Published var lessonsCompleted: Set<Int> = []
    @Published var achievementsUnlocked: Set<String> = []
    @Published var sessionHistory: [SessionRecord] = []
    @Published var showLevelUp: Bool = false
    @Published var levelUpToLevel: Int = 1
    @Published var dailyGoalSessions: Int = 3
    @Published var todaySessionCount: Int = 0

    let levelThresholds = [0, 100, 250, 500, 900, 1500, 2500, 4000, 6000, 10000]

    init() { load() }

    func load() {
        let ud = UserDefaults.standard
        userName = ud.string(forKey: UDKeys.userName) ?? ""
        userPhotoData = ud.data(forKey: UDKeys.userPhotoData)
        onboardingDone = ud.bool(forKey: UDKeys.onboardingDone)
        currentLevel = max(1, ud.integer(forKey: UDKeys.currentLevel))
        totalXP = ud.integer(forKey: UDKeys.totalXP)
        currentStreak = ud.integer(forKey: UDKeys.currentStreak)
        if let arr = ud.array(forKey: UDKeys.lessonsCompleted) as? [Int] {
            lessonsCompleted = Set(arr)
        }
        if let arr = ud.array(forKey: UDKeys.achievementsUnlocked) as? [String] {
            achievementsUnlocked = Set(arr)
        }
        if let data = ud.data(forKey: UDKeys.sessionHistory),
           let decoded = try? JSONDecoder().decode([SessionRecord].self, from: data) {
            sessionHistory = decoded
        }
        dailyGoalSessions = max(1, ud.integer(forKey: UDKeys.dailyGoalSessions) == 0 ? 3 : ud.integer(forKey: UDKeys.dailyGoalSessions))
        let todayStr = ISO8601DateFormatter().string(from: Calendar.current.startOfDay(for: Date()))
        if ud.string(forKey: UDKeys.dailyGoalDate) == todayStr {
            todaySessionCount = ud.integer(forKey: UDKeys.todaySessionCount)
        } else {
            todaySessionCount = 0
            ud.set(todayStr, forKey: UDKeys.dailyGoalDate)
            ud.set(0, forKey: UDKeys.todaySessionCount)
        }
        updateStreak()
        handleDailyLogin()
    }

    func save() {
        let ud = UserDefaults.standard
        ud.set(userName, forKey: UDKeys.userName)
        ud.set(userPhotoData, forKey: UDKeys.userPhotoData)
        ud.set(onboardingDone, forKey: UDKeys.onboardingDone)
        ud.set(currentLevel, forKey: UDKeys.currentLevel)
        ud.set(totalXP, forKey: UDKeys.totalXP)
        ud.set(currentStreak, forKey: UDKeys.currentStreak)
        ud.set(Array(lessonsCompleted), forKey: UDKeys.lessonsCompleted)
        ud.set(Array(achievementsUnlocked), forKey: UDKeys.achievementsUnlocked)
        ud.set(dailyGoalSessions, forKey: UDKeys.dailyGoalSessions)
        ud.set(todaySessionCount, forKey: UDKeys.todaySessionCount)
        let todayStr = ISO8601DateFormatter().string(from: Calendar.current.startOfDay(for: Date()))
        ud.set(todayStr, forKey: UDKeys.dailyGoalDate)
        if let data = try? JSONEncoder().encode(sessionHistory) {
            ud.set(data, forKey: UDKeys.sessionHistory)
        }
    }

    func addXP(_ amount: Int) {
        let oldLevel = currentLevel
        totalXP += amount
        recalcLevel()
        if currentLevel > oldLevel {
            levelUpToLevel = currentLevel
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                self.showLevelUp = true
            }
        }
        checkAchievements()
        save()
    }

    func recalcLevel() {
        var lv = 1
        for (i, threshold) in levelThresholds.enumerated() {
            if totalXP >= threshold { lv = i + 1 }
        }
        currentLevel = min(lv, levelThresholds.count)
    }

    func xpForCurrentLevel() -> Int {
        let idx = min(currentLevel - 1, levelThresholds.count - 1)
        return levelThresholds[idx]
    }

    func xpForNextLevel() -> Int {
        let idx = currentLevel
        if idx < levelThresholds.count { return levelThresholds[idx] }
        return levelThresholds.last!
    }

    func xpProgress() -> Double {
        let cur = xpForCurrentLevel()
        let next = xpForNextLevel()
        if next == cur { return 1.0 }
        return Double(totalXP - cur) / Double(next - cur)
    }

    func updateStreak() {
        let ud = UserDefaults.standard
        let cal = Calendar.current
        if let lastStr = ud.string(forKey: UDKeys.lastActiveDate),
           let lastDate = ISO8601DateFormatter().date(from: lastStr) {
            let days = cal.dateComponents([.day], from: lastDate, to: Date()).day ?? 0
            if days == 0 { return }
            else if days == 1 { currentStreak += 1 }
            else { currentStreak = 1 }
        } else {
            currentStreak = 1
        }
        ud.set(ISO8601DateFormatter().string(from: Date()), forKey: UDKeys.lastActiveDate)
        save()
    }

    func handleDailyLogin() {
        let ud = UserDefaults.standard
        let today = Calendar.current.startOfDay(for: Date())
        let todayStr = ISO8601DateFormatter().string(from: today)
        if ud.string(forKey: UDKeys.dailyLoginDate) != todayStr {
            ud.set(todayStr, forKey: UDKeys.dailyLoginDate)
            addXP(20)
            if currentStreak == 7 || currentStreak == 30 || currentStreak == 100 {
                addXP(200)
            }
        }
    }

    func completeLesson(_ id: Int) {
        guard !lessonsCompleted.contains(id) else { return }
        lessonsCompleted.insert(id)
        addXP(50)
        save()
    }

    func addSession(_ record: SessionRecord) {
        sessionHistory.append(record)
        if sessionHistory.count > 100 { sessionHistory.removeFirst() }
        todaySessionCount += 1
        save()
    }

    var dailyGoalProgress: Double {
        guard dailyGoalSessions > 0 else { return 1.0 }
        return min(1.0, Double(todaySessionCount) / Double(dailyGoalSessions))
    }

    func unlockAchievement(_ id: String) {
        guard !achievementsUnlocked.contains(id) else { return }
        achievementsUnlocked.insert(id)
        save()
    }

    func checkAchievements() {
        if totalXP >= 100 { unlockAchievement("first_steps") }
        if totalXP >= 500 { unlockAchievement("xp_500") }
        if totalXP >= 1000 { unlockAchievement("xp_1000") }
        if currentStreak >= 3 { unlockAchievement("streak_3") }
        if currentStreak >= 7 { unlockAchievement("streak_7") }
        if currentStreak >= 30 { unlockAchievement("streak_30") }
        if lessonsCompleted.count >= 1 { unlockAchievement("first_lesson") }
        if lessonsCompleted.count >= 6 { unlockAchievement("half_lessons") }
        if lessonsCompleted.count >= 12 { unlockAchievement("all_lessons") }
        if currentLevel >= 3 { unlockAchievement("level_3") }
        if currentLevel >= 5 { unlockAchievement("level_5") }
        if currentLevel >= 10 { unlockAchievement("level_max") }
    }

    func resetProgress() {
        totalXP = 0; currentLevel = 1; currentStreak = 0
        lessonsCompleted = []; achievementsUnlocked = []; sessionHistory = []
        save()
    }
}

// MARK: - Models
struct SessionRecord: Codable, Identifiable {
    var id: UUID = UUID()
    var date: Date
    var score: Int
    var xpEarned: Int
    var duration: Int
    var sessionType: String
}

struct Lesson: Identifiable {
    let id: Int
    let icon: String
    let title: String
    let description: String
    let difficulty: String
    let xpReward: Int
    let content: String
    var difficultyColor: Color {
        switch difficulty {
        case "Beginner": return .green
        case "Intermediate": return Color(red:0.2,green:0.6,blue:1)
        case "Advanced": return .purple
        default: return .gray
        }
    }
}

struct Achievement: Identifiable {
    let id: String
    let icon: String
    let name: String
    let description: String
    let rarity: Rarity
    enum Rarity { case common, rare, epic, legendary }
    var rarityColor: Color {
        switch rarity {
        case .common: return Color(.systemGray)
        case .rare: return Color(red:0.2,green:0.5,blue:1)
        case .epic: return Color(red:0.7,green:0.2,blue:1)
        case .legendary: return Color(red:1,green:0.8,blue:0.1)
        }
    }
    var rarityLabel: String {
        switch rarity {
        case .common: return "★ Common"
        case .rare: return "★★ Rare"
        case .epic: return "★★★ Epic"
        case .legendary: return "★★★★ Legendary"
        }
    }
}

struct QuizQuestion: Identifiable {
    let id: Int
    let question: String
    let type: QuestionType
    let options: [String]
    let correctAnswer: String
    let explanation: String
    enum QuestionType { case multipleChoice, trueFalse, fillIn }
}

// MARK: - Data Seeds
struct DataSeed {
    static let lessons: [Lesson] = [
        Lesson(id:0, icon:"brain.head.profile", title:"The Science of Deep Work", description:"Understand how focused attention reshapes your brain.", difficulty:"Beginner", xpReward:50, content:"Deep work is the ability to focus without distraction on cognitively demanding tasks. Neuroscientist Andrew Huberman explains that sustained focus triggers acetylcholine release in the prefrontal cortex, literally rewiring neural pathways for higher performance.\n\nKey principle: Start each session by acknowledging the discomfort of focus. That friction is neuroplasticity in action. Aim for 90-minute focused blocks aligned with your ultradian rhythm — your brain's natural 90-minute performance cycle.\n\nPractice: Schedule your first deep work block before checking any messages. Guard that window like a boardroom meeting with your future self."),
        Lesson(id:1, icon:"timer", title:"Pomodoro 2.0: Advanced Timing", description:"Go beyond basic 25-minute intervals with adaptive scheduling.", difficulty:"Beginner", xpReward:50, content:"The classic Pomodoro Technique (25 min work / 5 min break) is just the entry point. Research from the Draugiem Group found top performers work 52 minutes and break 17 minutes.\n\nAdaptive Pomodoro: Match your interval length to task complexity. Creative work → 45 min. Administrative tasks → 25 min. Learning new skills → 30 min.\n\nBreak quality matters as much as work quality. Avoid screens during breaks — a 5-minute walk increases creative output by 60% (Stanford, 2014). Hydrate, stretch, breathe. Your break is part of the system."),
        Lesson(id:2, icon:"list.bullet.clipboard", title:"Eat the Frog: Priority Mechanics", description:"Master task sequencing using cognitive load theory.", difficulty:"Beginner", xpReward:50, content:"Brian Tracy's 'Eat the Frog' principle: tackle your hardest, most important task first. Backed by cognitive load theory — decision fatigue is real and accumulates throughout the day.\n\nWillpower is like a muscle that tires. Roy Baumeister's research shows self-regulatory resources deplete with each decision. By doing your most demanding work first, you leverage peak prefrontal cortex performance.\n\nMorning Protocol: Before opening email or social media, identify your #1 priority for the day. Write it down the night before. Execute it before 11am. This single habit outperforms any productivity app."),
        Lesson(id:3, icon:"moon.zzz", title:"Sleep Architecture & Focus", description:"How sleep stages directly power your cognitive output.", difficulty:"Intermediate", xpReward:50, content:"Sleep isn't passive rest — it's active cognitive maintenance. During slow-wave sleep (N3), the glymphatic system clears metabolic waste from your brain, including beta-amyloid proteins linked to cognitive decline.\n\nREM sleep consolidates procedural memory and creative connections. Cutting your sleep from 8 to 6 hours doesn't cost 25% of performance — it costs 400% due to compound cognitive degradation.\n\nSleep optimization for performers: Maintain consistent wake time (±20 min). Keep your room at 65-68°F. Avoid caffeine after 2pm (12-hour half-life). A 20-minute nap between 1-3pm restores alertness by 34%."),
        Lesson(id:4, icon:"bolt.heart", title:"Energy Management vs Time Management", description:"Why managing energy beats managing time.", difficulty:"Intermediate", xpReward:50, content:"Tony Schwartz and Jim Loehr argue in 'The Power of Full Engagement' that energy, not time, is the fundamental currency of high performance. You can't manufacture more hours, but you can expand, renew, and sustain energy.\n\nFour energy dimensions: Physical (sleep, nutrition, exercise), Emotional (positivity, resilience), Mental (focus, cognitive), Spiritual (purpose, values alignment).\n\nPractical protocol: Audit where your energy goes, not just your time. Block recovery periods between high-intensity work sprints. Treat lunch as genuine restoration, not a task to complete at your desk."),
        Lesson(id:5, icon:"network", title:"Second Brain: External Cognition", description:"Build a trusted system to offload mental overhead.", difficulty:"Intermediate", xpReward:50, content:"Tiago Forte's 'Building a Second Brain' (BASB) methodology uses the CODE framework: Capture, Organize, Distill, Express. The goal is to offload your working memory into a trusted external system.\n\nThe Zeigarnik Effect: Your brain nags you about unfinished tasks. A trusted capture system (notebook, app) tells your subconscious it's safe to let go — reducing mental overhead by up to 30%.\n\nImplementation: Choose one capture tool. Anything that enters your mind goes there immediately. Weekly review: process inbox, tag by project, distill key insights. Your brain is for thinking, not storage."),
        Lesson(id:6, icon:"chart.line.uptrend.xyaxis", title:"Flow State Engineering", description:"Reliably trigger peak performance states on demand.", difficulty:"Advanced", xpReward:50, content:"Mihaly Csikszentmihalyi defined flow as the state where challenge perfectly matches skill. In flow, the prefrontal cortex partially deactivates (transient hypofrontality), reducing self-consciousness and unlocking faster, more creative thinking.\n\nFlow triggers: Clear goals + immediate feedback + challenge/skill balance (4% beyond current ability). Environment: eliminate interruptions, use binaural beats (40Hz gamma), set a visible countdown timer.\n\nFlow onset takes 15-20 minutes of uninterrupted focus. Any interruption resets the clock. Protect that window ferociously. Batch all notifications to 3x daily check-ins."),
        Lesson(id:7, icon:"person.2.wave.2", title:"Accountability Architecture", description:"Engineer social structures that guarantee follow-through.", difficulty:"Advanced", xpReward:50, content:"The American Society of Training and Development found that having a specific accountability partner increases goal completion probability from 65% to 95%.\n\nAccountability structures from weakest to strongest: Written goal (39% success) → public declaration (65%) → weekly check-in partner (72%) → coaching relationship (85%) → financial stake + partner (95%).\n\nDesign your system: Pick one high-stakes goal. Find an accountability partner with aligned ambitions. Schedule weekly 15-minute calls with a simple format: What did you commit to? Did you do it? What's next week's commitment?"),
        Lesson(id:8, icon:"waveform.path.ecg", title:"Stress Inoculation for Performers", description:"Use controlled stress to build elite cognitive resilience.", difficulty:"Advanced", xpReward:50, content:"Navy SEALs use stress inoculation training — deliberately exposing trainees to controlled stressors to build tolerance. The same principle applies to cognitive performance.\n\nAdrenaline (epinephrine) impairs prefrontal cortex function — the region responsible for complex decision-making. By repeatedly working in mild-stress conditions, you train your nervous system to maintain cortical function under pressure.\n\nPractice: Time-constrain your work deliberately. Use cold exposure (cold shower, 2 min) before demanding cognitive sessions — it spikes norepinephrine, enhancing focus for 2-4 hours. Deliberate discomfort builds focus range."),
        Lesson(id:9, icon:"lightbulb.max", title:"Idea Generation Systems", description:"Structured techniques to generate breakthrough solutions.", difficulty:"Beginner", xpReward:50, content:"Creativity isn't magic — it's combinatorial. James Webb Young's insight: 'An idea is nothing more nor less than a new combination of old elements.' The more inputs you expose yourself to, the more combinations your brain can generate.\n\nScamper Technique: Substitute, Combine, Adapt, Modify, Put to other uses, Eliminate, Reverse. Apply to any challenge.\n\nIdea generation protocol: Set a timer for 10 minutes. Write 20 ideas on your topic — without filtering. The first 10 will be obvious. Ideas 11-20 are where breakthroughs live. Quantity creates quality."),
        Lesson(id:10, icon:"figure.walk.motion", title:"Movement as Cognitive Fuel", description:"How physical activity directly upgrades your brain.", difficulty:"Beginner", xpReward:50, content:"John Ratey, Harvard psychiatrist and author of 'Spark,' demonstrates that aerobic exercise is the most potent cognitive enhancer available. 20 minutes of moderate cardio increases BDNF (brain-derived neurotrophic factor) — the 'Miracle-Gro' for neurons.\n\nSpecific effects: Exercise before learning increases retention by 20%. A 10-minute walk improves working memory for 2 hours. Regular cardio grows the hippocampus — reversing age-related shrinkage.\n\nMinimum effective dose: 20 minutes of Zone 2 cardio (can hold a conversation) 3-4x per week. Walk during phone calls. Take stairs. Microbursts of movement between focus sessions are powerful."),
        Lesson(id:11, icon:"calendar.badge.checkmark", title:"Weekly Review Mastery", description:"The 30-minute ritual that multiplies your entire week.", difficulty:"Intermediate", xpReward:50, content:"David Allen's Getting Things Done (GTD) identifies the Weekly Review as the cornerstone habit — the 'master key' that keeps the whole system functional. Without it, your trusted system becomes an anxiety generator.\n\nWeekly Review protocol (30 min every Friday): 1) Collect — gather all loose papers, notes, items from everywhere. 2) Process — what is it? Is it actionable? What's the next action? 3) Review — all active projects, waiting-for items, someday list. 4) Update — add new projects, close complete ones. 5) Get creative — brainstorm, plan next week.\n\nSchedule this as a non-negotiable calendar appointment.")
    ]

    static let achievements: [Achievement] = [
        Achievement(id:"first_steps", icon:"shoeprints.fill", name:"First Steps", description:"Earn your first 100 XP", rarity:.common),
        Achievement(id:"first_lesson", icon:"book.fill", name:"Knowledge Seeker", description:"Complete your first lesson", rarity:.common),
        Achievement(id:"streak_3", icon:"flame.fill", name:"Spark Ignited", description:"Maintain a 3-day streak", rarity:.common),
        Achievement(id:"xp_500", icon:"star.fill", name:"Rising Star", description:"Accumulate 500 total XP", rarity:.rare),
        Achievement(id:"half_lessons", icon:"books.vertical.fill", name:"Deep Learner", description:"Complete 6 lessons", rarity:.rare),
        Achievement(id:"streak_7", icon:"bolt.fill", name:"Week Warrior", description:"Maintain a 7-day streak", rarity:.rare),
        Achievement(id:"level_3", icon:"chart.bar.fill", name:"Momentum Builder", description:"Reach Level 3", rarity:.rare),
        Achievement(id:"xp_1000", icon:"crown.fill", name:"Focus Elite", description:"Accumulate 1000 total XP", rarity:.epic),
        Achievement(id:"all_lessons", icon:"checkmark.seal.fill", name:"Curriculum Conqueror", description:"Complete all 12 lessons", rarity:.epic),
        Achievement(id:"level_5", icon:"waveform.path.ecg.rectangle.fill", name:"Flow State Architect", description:"Reach Level 5", rarity:.epic),
        Achievement(id:"streak_30", icon:"moon.stars.fill", name:"Iron Mind", description:"Maintain a 30-day streak", rarity:.legendary),
        Achievement(id:"level_max", icon:"burst.fill", name:"CoCoFocus Core Legend", description:"Reach the maximum level", rarity:.legendary)
    ]

    static let questions: [QuizQuestion] = [
        QuizQuestion(id:0, question:"What neurotransmitter is primarily released during deep focused work that strengthens neural connections?", type:.multipleChoice, options:["Dopamine","Acetylcholine","Serotonin","GABA"], correctAnswer:"Acetylcholine", explanation:"Acetylcholine is released in the prefrontal cortex during sustained focus, driving neuroplasticity."),
        QuizQuestion(id:1, question:"The Pomodoro Technique was created by which entrepreneur/author?", type:.multipleChoice, options:["David Allen","Francesco Cirillo","Tony Schwartz","Cal Newport"], correctAnswer:"Francesco Cirillo", explanation:"Francesco Cirillo developed the Pomodoro Technique in the late 1980s using a tomato-shaped kitchen timer."),
        QuizQuestion(id:2, question:"Research shows top performers tend to work for approximately how many consecutive minutes before taking a break?", type:.multipleChoice, options:["25 minutes","45 minutes","52 minutes","90 minutes"], correctAnswer:"52 minutes", explanation:"Draugiem Group research found the most productive people work ~52 minutes then break for ~17 minutes."),
        QuizQuestion(id:3, question:"True or False: Checking email first thing in the morning is recommended by most productivity experts.", type:.trueFalse, options:["True","False"], correctAnswer:"False", explanation:"Most experts recommend completing your #1 priority task before checking email to protect peak cognitive hours."),
        QuizQuestion(id:4, question:"The Zeigarnik Effect refers to the brain's tendency to:", type:.multipleChoice, options:["Remember completed tasks better","Obsess over unfinished tasks","Focus better under stress","Learn faster through repetition"], correctAnswer:"Obsess over unfinished tasks", explanation:"Bluma Zeigarnik discovered we remember and ruminate on interrupted or incomplete tasks far more than completed ones."),
        QuizQuestion(id:5, question:"What is the term for the brain's partial deactivation of the prefrontal cortex during flow state?", type:.multipleChoice, options:["Cognitive offloading","Transient hypofrontality","Neural plasticity","Default mode activation"], correctAnswer:"Transient hypofrontality", explanation:"Transient hypofrontality reduces self-consciousness and internal chatter, enabling the effortless focus of flow."),
        QuizQuestion(id:6, question:"According to ASTD research, what percentage chance of goal completion do you have with a specific accountability partner and regular check-ins?", type:.multipleChoice, options:["65%","72%","85%","95%"], correctAnswer:"95%", explanation:"Having an accountability partner with specific commitments and regular check-ins boosts success probability to 95%."),
        QuizQuestion(id:7, question:"True or False: A 20-minute nap between 1-3pm has been shown to restore alertness by approximately 34%.", type:.trueFalse, options:["True","False"], correctAnswer:"True", explanation:"NASA research confirmed that a 26-minute nap improved pilot performance by 34% and alertness by 100%."),
        QuizQuestion(id:8, question:"BDNF, which increases with aerobic exercise, is nicknamed what by neuroscientists?", type:.multipleChoice, options:["Neuro-fuel","Miracle-Gro for the brain","Plasticity protein","Focus enzyme"], correctAnswer:"Miracle-Gro for the brain", explanation:"John Ratey coined this nickname for BDNF (Brain-Derived Neurotrophic Factor) in his book Spark."),
        QuizQuestion(id:9, question:"In GTD (Getting Things Done), which weekly ritual does David Allen call the 'master key' of the system?", type:.multipleChoice, options:["Daily review","Weekly Review","Monthly audit","Project sweep"], correctAnswer:"Weekly Review", explanation:"The Weekly Review ensures your trusted system stays current and your mind can fully relax."),
        QuizQuestion(id:10, question:"True or False: Cutting sleep from 8 to 6 hours costs approximately 25% of cognitive performance.", type:.trueFalse, options:["True","False"], correctAnswer:"False", explanation:"Due to compound effects, sleep restriction from 8 to 6 hours costs approximately 400% of performance loss."),
        QuizQuestion(id:11, question:"The 'challenge/skill balance' for triggering flow state should be approximately how far beyond your current skill level?", type:.multipleChoice, options:["1%","4%","10%","25%"], correctAnswer:"4%", explanation:"Csikszentmihalyi's research found the optimal flow trigger is a challenge about 4% beyond current ability."),
        QuizQuestion(id:12, question:"Which cognitive resource depletes with repeated decisions throughout the day, according to Roy Baumeister?", type:.multipleChoice, options:["Working memory","Self-regulatory capacity (willpower)","Long-term memory","Spatial reasoning"], correctAnswer:"Self-regulatory capacity (willpower)", explanation:"Baumeister's ego depletion research shows willpower is a limited resource that tires with use."),
        QuizQuestion(id:13, question:"True or False: The glymphatic system clears toxic brain waste primarily during deep sleep (N3 stage).", type:.trueFalse, options:["True","False"], correctAnswer:"True", explanation:"The glymphatic system is nearly 10x more active during sleep, flushing out waste including Alzheimer's-linked proteins."),
        QuizQuestion(id:14, question:"Walking outside increases creative output by approximately what percentage, according to Stanford research?", type:.multipleChoice, options:["20%","40%","60%","80%"], correctAnswer:"60%", explanation:"Stanford researchers found walking, especially outdoors, boosts creative output by an average of 60%."),
        QuizQuestion(id:15, question:"Which framework does Tiago Forte use in 'Building a Second Brain'?", type:.multipleChoice, options:["GTD","SCAMPER","CODE","PARA"], correctAnswer:"CODE", explanation:"CODE stands for Capture, Organize, Distill, Express — the core workflow of the Second Brain methodology."),
        QuizQuestion(id:16, question:"True or False: Binaural beats at 40Hz (gamma frequency) have been associated with enhanced focus and cognitive performance.", type:.trueFalse, options:["True","False"], correctAnswer:"True", explanation:"40Hz gamma binaural beats have shown cognitive benefits in multiple studies, potentially boosting focus and memory."),
        QuizQuestion(id:17, question:"In the Four Energy Dimensions model, which dimension relates to sense of purpose and values?", type:.multipleChoice, options:["Physical","Emotional","Mental","Spiritual"], correctAnswer:"Spiritual", explanation:"The Spiritual dimension in Schwartz & Loehr's model encompasses purpose, values alignment, and meaning."),
        QuizQuestion(id:18, question:"How long does it typically take to reach an initial flow state once uninterrupted focus begins?", type:.multipleChoice, options:["2-5 minutes","10-12 minutes","15-20 minutes","30-40 minutes"], correctAnswer:"15-20 minutes", explanation:"Flow onset typically requires 15-20 minutes of uninterrupted focus — any interruption resets this timer."),
        QuizQuestion(id:19, question:"True or False: In the Eat the Frog method, you should tackle your easiest task first to build momentum.", type:.trueFalse, options:["True","False"], correctAnswer:"False", explanation:"Eat the Frog means tackling your hardest, most important task first, while cognitive resources are at their peak.")
    ]
}

// MARK: - Design System
struct DS {
    static let bg = Color(red:0.04, green:0.07, blue:0.05)
    static let bgMid = Color(red:0.06, green:0.11, blue:0.07)
    static let green = Color(red:0.1, green:0.95, blue:0.45)
    static let greenDark = Color(red:0.05, green:0.55, blue:0.25)
    static let greenMid = Color(red:0.07, green:0.75, blue:0.35)
    static let cardBg = Color(red:0.06, green:0.10, blue:0.07)
    static let cyan = Color(red:0.0, green:0.9, blue:0.85)
    static let purple = Color(red:0.55, green:0.1, blue:0.95)
    static let gold = Color(red:1.0, green:0.82, blue:0.15)
    static let red = Color(red:0.95, green:0.2, blue:0.3)

    static var mainGradient: LinearGradient {
        LinearGradient(colors:[bg, bgMid, Color(red:0.03,green:0.09,blue:0.06)], startPoint:.topLeading, endPoint:.bottomTrailing)
    }
    static var greenGradient: LinearGradient {
        LinearGradient(colors:[green, greenMid], startPoint:.topLeading, endPoint:.bottomTrailing)
    }
    static var cardGradient: LinearGradient {
        LinearGradient(colors:[cardBg, Color(red:0.05,green:0.12,blue:0.07)], startPoint:.topLeading, endPoint:.bottomTrailing)
    }
}

// MARK: - Reusable Components
struct GlowingText: View {
    let text: String
    let font: Font
    let color: Color
    var body: some View {
        Text(text).font(font).foregroundColor(color)
            .shadow(color:color.opacity(0.8), radius:8)
            .shadow(color:color.opacity(0.4), radius:16)
    }
}

struct CyberCard<Content: View>: View {
    let content: Content
    var glowColor: Color = DS.green
    init(glowColor: Color = DS.green, @ViewBuilder content: () -> Content) {
        self.content = content()
        self.glowColor = glowColor
    }
    var body: some View {
        content
            .background(DS.cardGradient)
            .clipShape(RoundedRectangle(cornerRadius:20))
            .overlay(RoundedRectangle(cornerRadius:20).stroke(LinearGradient(colors:[glowColor.opacity(0.8), glowColor.opacity(0.2)], startPoint:.topLeading, endPoint:.bottomTrailing), lineWidth:1))
            .shadow(color:glowColor.opacity(0.25), radius:12)
    }
}

struct PressButton<Content: View>: View {
    let action: () -> Void
    let content: Content
    @State private var pressed = false
    init(action: @escaping () -> Void, @ViewBuilder content: () -> Content) {
        self.action = action; self.content = content()
    }
    var body: some View {
        Button(action:{
            let impact = UIImpactFeedbackGenerator(style:.medium); impact.impactOccurred()
            action()
        }) { content }
        .buttonStyle(PressStyle())
    }
}

struct PressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.94 : 1.0)
            .animation(.spring(response:0.2,dampingFraction:0.6), value:configuration.isPressed)
    }
}

struct XPBar: View {
    let progress: Double
    var color: Color = DS.green
    @State private var animatedProgress: Double = 0
    var body: some View {
        GeometryReader { geo in
            ZStack(alignment:.leading) {
                RoundedRectangle(cornerRadius:6).fill(Color.white.opacity(0.1)).frame(height:8)
                RoundedRectangle(cornerRadius:6)
                    .fill(LinearGradient(colors:[color, color.opacity(0.6)], startPoint:.leading, endPoint:.trailing))
                    .frame(width:geo.size.width * animatedProgress, height:8)
                    .shadow(color:color.opacity(0.6), radius:4)
            }
        }.frame(height:8)
        .onAppear { withAnimation(.easeOut(duration:1.0)) { animatedProgress = progress } }
        .onChange(of:progress) { newVal in withAnimation(.easeOut(duration:0.5)) { animatedProgress = newVal } }
    }
}

struct ScanlineOverlay: View {
    var body: some View {
        GeometryReader { geo in
            VStack(spacing:4) {
                ForEach(0..<Int(geo.size.height/6), id:\.self) { _ in
                    Rectangle().fill(Color.black.opacity(0.06)).frame(height:1)
                    Spacer(minLength:3)
                }
            }
        }.allowsHitTesting(false)
    }
}

struct GridBackground: View {
    var body: some View {
        GeometryReader { geo in
            Canvas { context, size in
                let spacing: CGFloat = 32
                var path = Path()
                var x: CGFloat = 0
                while x <= size.width { path.move(to:CGPoint(x:x,y:0)); path.addLine(to:CGPoint(x:x,y:size.height)); x += spacing }
                var y: CGFloat = 0
                while y <= size.height { path.move(to:CGPoint(x:0,y:y)); path.addLine(to:CGPoint(x:size.width,y:y)); y += spacing }
                context.stroke(path, with:.color(DS.green.opacity(0.07)), lineWidth:0.5)
            }
        }.allowsHitTesting(false)
    }
}

// MARK: - Particle System
struct Particle: Identifiable {
    let id = UUID()
    var x: CGFloat; var y: CGFloat
    var vx: CGFloat; var vy: CGFloat
    var life: Double; var maxLife: Double
    var size: CGFloat; var color: Color
}

class ParticleSystem: ObservableObject {
    @Published var particles: [Particle] = []
    private var timer: Timer?
    func start(in size: CGSize) {
        timer = Timer.scheduledTimer(withTimeInterval:0.05, repeats:true) { [weak self] _ in
            self?.update(size:size)
        }
        for _ in 0..<30 { spawnParticle(in:size) }
    }
    func stop() { timer?.invalidate(); timer = nil }
    func spawnParticle(in size: CGSize) {
        let colors: [Color] = [DS.green, DS.cyan, DS.greenMid, Color.white.opacity(0.6)]
        particles.append(Particle(
            x:CGFloat.random(in:0...size.width), y:CGFloat.random(in:0...size.height),
            vx:CGFloat.random(in:-0.5...0.5), vy:CGFloat.random(in:-1.5...(-0.3)),
            life:Double.random(in:0...3), maxLife:Double.random(in:2...5),
            size:CGFloat.random(in:1...3.5),
            color:colors.randomElement()!
        ))
    }
    func update(size: CGSize) {
        particles = particles.compactMap { var p = $0
            p.x += p.vx; p.y += p.vy; p.life += 0.05
            if p.life > p.maxLife || p.y < -10 { return nil }
            return p
        }
        while particles.count < 30 { spawnParticle(in:size) }
    }
}

struct ParticleView: View {
    @StateObject private var system = ParticleSystem()
    var body: some View {
        GeometryReader { geo in
            ZStack {
                ForEach(system.particles) { p in
                    Circle()
                        .fill(p.color)
                        .frame(width:p.size, height:p.size)
                        .position(x:p.x, y:p.y)
                        .opacity(1 - (p.life/p.maxLife))
                        .blur(radius:p.size * 0.3)
                }
            }
            .onAppear { system.start(in:geo.size) }
            .onDisappear { system.stop() }
        }.allowsHitTesting(false)
    }
}

// MARK: - Root View
struct RootView: View {
    @StateObject private var appState = AppState.shared
    @State private var splashDone = false
    @State private var tabBarVisible = false

    var body: some View {
        ZStack {
            if !splashDone {
                SplashScreen(onDone: {
                    withAnimation(.spring(response:0.7, dampingFraction:0.7)) {
                        splashDone = true
                        tabBarVisible = true
                    }
                })
                .transition(.opacity)
            } else {
                Group {
                    if !appState.onboardingDone {
                        OnboardingView()
                    } else {
                        MainTabView()
                    }
                }
                .opacity(tabBarVisible ? 1 : 0)
                .scaleEffect(tabBarVisible ? 1 : 0.92)
            }
            if appState.showLevelUp {
                LevelUpOverlay(level: appState.levelUpToLevel) {
                    appState.showLevelUp = false
                }
                .transition(.opacity)
                .zIndex(100)
            }
        }
        .environmentObject(appState)
    }
}

// MARK: - Splash Screen
struct SplashScreen: View {
    let onDone: () -> Void
    @State private var logoScale: CGFloat = 0.3
    @State private var logoOpacity: Double = 0
    @State private var glowRadius: CGFloat = 5
    @State private var progressValue: CGFloat = 0
    @State private var subtitleOpacity: Double = 0

    var body: some View {
        ZStack {
            DS.mainGradient.ignoresSafeArea()
            GridBackground()
            ParticleView()
            ScanlineOverlay()

            LinearGradient(colors:[DS.green.opacity(0.15), DS.cyan.opacity(0.08), DS.purple.opacity(0.1)],
                           startPoint:.topLeading, endPoint:.bottomTrailing).ignoresSafeArea()

            VStack(spacing:32) {
                Spacer()
                ZStack {
                    Circle().fill(DS.green.opacity(0.12)).frame(width:160, height:160)
                        .shadow(color:DS.green.opacity(0.5), radius:glowRadius * 4)
                    Circle().stroke(DS.green.opacity(0.3), lineWidth:1).frame(width:180,height:180)
                    Circle().stroke(DS.cyan.opacity(0.2), lineWidth:1).frame(width:210,height:210)
                    Image(systemName:"brain.head.profile")
                        .resizable().scaledToFit().frame(width:70,height:70)
                        .foregroundStyle(LinearGradient(colors:[DS.green, DS.cyan], startPoint:.topLeading, endPoint:.bottomTrailing))
                        .shadow(color:DS.green.opacity(0.9), radius:glowRadius * 2)
                }
                .scaleEffect(logoScale).opacity(logoOpacity)

                VStack(spacing:8) {
                    GlowingText(text:"COCOFOCUS CORE", font:.system(size:38,weight:.black,design:.monospaced), color:DS.green)
                    Text("Master Your Focus. Command Your Time.")
                        .font(.system(size:14, weight:.medium, design:.monospaced))
                        .foregroundColor(DS.green.opacity(0.7))
                        .opacity(subtitleOpacity)
                }

                Spacer()

                VStack(spacing:10) {
                    Text("INITIALIZING").font(.system(size:11, weight:.medium, design:.monospaced)).foregroundColor(DS.green.opacity(0.5))
                    ZStack(alignment:.leading) {
                        RoundedRectangle(cornerRadius:4).fill(Color.white.opacity(0.08)).frame(height:4)
                        GeometryReader { geo in
                            RoundedRectangle(cornerRadius:4)
                                .fill(LinearGradient(colors:[DS.green, DS.cyan], startPoint:.leading, endPoint:.trailing))
                                .frame(width:geo.size.width * progressValue, height:4)
                                .shadow(color:DS.green.opacity(0.8), radius:4)
                        }.frame(height:4)
                    }.frame(width:200)
                }.padding(.bottom, 60)
            }
        }
        .onAppear {
            withAnimation(.spring(response:0.8, dampingFraction:0.6).delay(0.2)) { logoScale = 1; logoOpacity = 1 }
            withAnimation(.easeIn(duration:0.5).delay(0.7)) { subtitleOpacity = 1 }
            withAnimation(.easeInOut(duration:0.6).repeatForever(autoreverses:true)) { glowRadius = 15 }
            withAnimation(.easeInOut(duration:2.8).delay(0.2)) { progressValue = 1 }
            DispatchQueue.main.asyncAfter(deadline:.now()+3.0) { onDone() }
        }
    }
}

// MARK: - Onboarding
struct OnboardingView: View {
    @EnvironmentObject var appState: AppState
    @State private var step = 0
    @State private var name = ""
    @State private var selectedImage: UIImage? = nil
    @State private var showImagePicker = false
    @State private var stepOffset: CGFloat = 0

    var body: some View {
        ZStack {
            stepBackground(step).ignoresSafeArea()
            GridBackground()
            ScanlineOverlay()
            ParticleView()
            VStack {
                HStack {
                    Spacer()
                    Button("Skip") {
                        finishOnboarding()
                    }
                    .font(.system(size:14, weight:.semibold, design:.monospaced))
                    .foregroundColor(DS.green.opacity(0.7))
                    .padding()
                }
                Spacer()
                Group {
                    if step == 0 { onboardStep0 }
                    else if step == 1 { onboardStep1 }
                    else { onboardStep2 }
                }
                .transition(.asymmetric(insertion:.move(edge:.trailing).combined(with:.opacity), removal:.move(edge:.leading).combined(with:.opacity)))
                Spacer()
                VStack(spacing:20) {
                    HStack(spacing:10) {
                        ForEach(0..<3) { i in
                            Circle()
                                .fill(i == step ? DS.green : DS.green.opacity(0.25))
                                .frame(width:i == step ? 12 : 8, height:i == step ? 12 : 8)
                                .animation(.spring(), value:step)
                        }
                    }
                    PressButton(action:{ nextStep() }) {
                        HStack {
                            Text(step < 2 ? "CONTINUE" : "LET'S GO")
                                .font(.system(size:16, weight:.black, design:.monospaced))
                            Image(systemName:"arrow.right")
                        }
                        .foregroundColor(.black)
                        .frame(maxWidth:.infinity).padding(.vertical,16)
                        .background(DS.greenGradient)
                        .clipShape(RoundedRectangle(cornerRadius:16))
                        .shadow(color:DS.green.opacity(0.5), radius:12)
                    }.padding(.horizontal,32)
                }.padding(.bottom,50)
            }
        }
        .sheet(isPresented:$showImagePicker) {
            ImagePicker(image:$selectedImage)
        }
    }

    func stepBackground(_ s: Int) -> some View {
        let colors: [[Color]] = [
            [DS.bg, Color(red:0.04,green:0.12,blue:0.08), Color(red:0.02,green:0.08,blue:0.05)],
            [DS.bg, Color(red:0.06,green:0.05,blue:0.12), Color(red:0.03,green:0.07,blue:0.10)],
            [DS.bg, Color(red:0.08,green:0.06,blue:0.04), Color(red:0.04,green:0.10,blue:0.07)]
        ]
        return LinearGradient(colors:colors[s], startPoint:.topLeading, endPoint:.bottomTrailing)
    }

    var onboardStep0: some View {
        VStack(spacing:28) {
            ZStack {
                ForEach(0..<3) { i in
                    Circle().stroke(DS.green.opacity(0.15 - Double(i)*0.04), lineWidth:1)
                        .frame(width:CGFloat(140 + i*40), height:CGFloat(140 + i*40))
                        .scaleEffect(1 + CGFloat(i)*0.05)
                }
                Image(systemName:"brain.head.profile")
                    .resizable().scaledToFit().frame(width:80,height:80)
                    .foregroundStyle(LinearGradient(colors:[DS.green,DS.cyan], startPoint:.topLeading, endPoint:.bottomTrailing))
                    .shadow(color:DS.green, radius:16)
            }
            VStack(spacing:12) {
                GlowingText(text:"WELCOME TO\nCOCOFOCUS CORE", font:.system(size:32,weight:.black,design:.monospaced), color:DS.green)
                    .multilineTextAlignment(.center)
                Text("Your command center for deep focus,\nmasterful time management, and\nunbreakable productivity habits.")
                    .font(.system(size:15, weight:.regular, design:.rounded))
                    .foregroundColor(.white.opacity(0.75))
                    .multilineTextAlignment(.center)
                    .padding(.horizontal,20)
            }
        }.padding(.horizontal,24)
    }

    var onboardStep1: some View {
        VStack(spacing:20) {
            GlowingText(text:"YOUR TOOLKIT", font:.system(size:28,weight:.black,design:.monospaced), color:DS.cyan)
                .padding(.bottom,8)
            ForEach([
                ("timer","Pomodoro Focus Timer","Precision timing with streak tracking"),
                ("books.vertical","12 Mastery Lessons","Science-backed focus training"),
                ("gamecontroller","Focus Challenge Quiz","Test knowledge. Earn XP. Level up."),
                ("chart.xyaxis.line","Performance Analytics","Track every dimension of your output")
            ], id:\.0) { icon, title, desc in
                CyberCard(glowColor:DS.cyan) {
                    HStack(spacing:16) {
                        Image(systemName:icon).font(.title2)
                            .foregroundStyle(LinearGradient(colors:[DS.cyan, DS.green], startPoint:.topLeading, endPoint:.bottomTrailing))
                            .frame(width:44)
                        VStack(alignment:.leading, spacing:3) {
                            Text(title).font(.system(size:14,weight:.bold,design:.monospaced)).foregroundColor(.white)
                            Text(desc).font(.system(size:12)).foregroundColor(.white.opacity(0.6))
                        }
                        Spacer()
                    }.padding(14)
                }
            }
        }.padding(.horizontal,24)
    }

    var onboardStep2: some View {
        VStack(spacing:28) {
            GlowingText(text:"SET YOUR IDENTITY", font:.system(size:26,weight:.black,design:.monospaced), color:DS.gold)
            PressButton(action:{ showImagePicker = true }) {
                ZStack {
                    Circle().fill(DS.cardBg).frame(width:110,height:110)
                    Circle().stroke(DS.gold.opacity(0.7), lineWidth:2).frame(width:110,height:110)
                    if let img = selectedImage {
                        Image(uiImage:img).resizable().scaledToFill()
                            .frame(width:106,height:106).clipShape(Circle())
                    } else {
                        VStack(spacing:6) {
                            Image(systemName:"camera.fill").font(.title2).foregroundColor(DS.gold.opacity(0.8))
                            Text("ADD PHOTO").font(.system(size:10,weight:.bold,design:.monospaced)).foregroundColor(DS.gold.opacity(0.6))
                        }
                    }
                }
            }
            CyberCard(glowColor:DS.gold) {
                VStack(alignment:.leading, spacing:8) {
                    Text("YOUR NAME").font(.system(size:11,weight:.bold,design:.monospaced)).foregroundColor(DS.gold.opacity(0.7))
                    TextField("Enter your name...", text:$name)
                        .font(.system(size:16, weight:.medium, design:.monospaced))
                        .foregroundColor(.white)
                        .tint(DS.gold)
                }.padding(16)
            }.padding(.horizontal,24)
            Text("This personalizes your focus journey.\nAll data stays on your device.")
                .font(.system(size:12)).foregroundColor(.white.opacity(0.5))
                .multilineTextAlignment(.center)
        }.padding(.horizontal,24)
    }

    func nextStep() {
        if step < 2 { withAnimation(.spring()) { step += 1 } }
        else { finishOnboarding() }
    }

    func finishOnboarding() {
        if !name.isEmpty { appState.userName = name }
        if let img = selectedImage { appState.userPhotoData = img.jpegData(compressionQuality:0.8) }
        appState.onboardingDone = true
        appState.save()
    }
}

// MARK: - Main Tab View
struct MainTabView: View {
    @State private var selectedTab = 0
    @State private var tabAnimations: [Bool] = [false, false, false, false, false]

    var body: some View {
        ZStack(alignment:.bottom) {
            TabView(selection:$selectedTab) {
                DashboardView().tag(0)
                LessonsView().tag(1)
                QuizView().tag(2)
                AnalyticsView().tag(3)
                ProfileView().tag(4)
            }
            .tabViewStyle(.page(indexDisplayMode:.never))

            CustomTabBar(selectedTab:$selectedTab, animations:$tabAnimations)
                .padding(.horizontal,20)
                .padding(.bottom, 16)
        }
        .ignoresSafeArea(edges:.bottom)
        .onChange(of:selectedTab) { _ in
            let impact = UIImpactFeedbackGenerator(style:.light); impact.impactOccurred()
        }
    }
}

struct CustomTabBar: View {
    @Binding var selectedTab: Int
    @Binding var animations: [Bool]
    let tabs: [(icon:String, label:String)] = [
        ("house.fill","Focus"), ("books.vertical.fill","Learn"),
        ("gamecontroller.fill","Challenge"), ("chart.xyaxis.line","Stats"),
        ("person.fill","Profile")
    ]

    var body: some View {
        HStack(spacing:0) {
            ForEach(0..<tabs.count, id:\.self) { i in
                Spacer()
                PressButton(action:{ selectTab(i) }) {
                    VStack(spacing:4) {
                        ZStack {
                            if selectedTab == i {
                                RoundedRectangle(cornerRadius:12)
                                    .fill(DS.green.opacity(0.2))
                                    .frame(width:48,height:38)
                                    .shadow(color:DS.green.opacity(0.5), radius:8)
                            }
                            Image(systemName:tabs[i].icon)
                                .font(.system(size:20, weight:selectedTab==i ? .bold : .regular))
                                .foregroundStyle(selectedTab==i ?
                                    AnyShapeStyle(LinearGradient(colors:[DS.green, DS.cyan], startPoint:.topLeading, endPoint:.bottomTrailing)) :
                                    AnyShapeStyle(Color.white.opacity(0.4))
                                )
                                .scaleEffect(animations[i] ? 1.3 : 1.0)
                        }
                        Text(tabs[i].label)
                            .font(.system(size:10, weight:.medium, design:.monospaced))
                            .foregroundColor(selectedTab==i ? DS.green : .white.opacity(0.4))
                    }
                }
                Spacer()
            }
        }
        .padding(.vertical,10)
        .background(
            RoundedRectangle(cornerRadius:28)
                .fill(Color(red:0.06,green:0.10,blue:0.07).opacity(0.95))
                .overlay(RoundedRectangle(cornerRadius:28).stroke(DS.green.opacity(0.3), lineWidth:1))
                .shadow(color:DS.green.opacity(0.2), radius:16)
        )
    }

    func selectTab(_ i: Int) {
        selectedTab = i
        withAnimation(.spring(response:0.2,dampingFraction:0.4)) { animations[i] = true }
        DispatchQueue.main.asyncAfter(deadline:.now()+0.3) { withAnimation { animations[i] = false } }
    }
}

// MARK: - Dashboard
struct DashboardView: View {
    @EnvironmentObject var appState: AppState
    @State private var showSettings = false
    @State private var showFocusTimer = false
    @State private var showBreathingExercise = false
    @State private var flameScale: CGFloat = 1.0
    @State private var cardAppear = false
    @State private var tipIndex = 0
    @State private var quoteIndex = 0
    @State private var goalRingProgress: Double = 0

    let tips = [
        "Schedule deep work in your first 90 minutes after waking — your prefrontal cortex is at peak power.",
        "The Pomodoro break is NOT optional. Rest is part of the performance system.",
        "Write tomorrow's #1 priority tonight. Decision fatigue won't rob your morning.",
        "Your phone in another room increases focus by 30% vs on your desk, face down.",
        "Flow state needs 15-20 min to reach. Protect that window like your most important meeting.",
        "Energy management > time management. You can't manufacture more hours.",
        "A 2-minute cold shower before deep work spikes norepinephrine for hours.",
        "Accountability partners increase goal completion from 65% to 95%.",
        "Sleep 7-9 hours. Cutting 2 hours doesn't cost 25% performance — it costs 400%.",
        "Walking 20 min increases creative output by 60%. Schedule it."
    ]

    let quotes: [(text: String, author: String)] = [
        ("The successful warrior is the average man, with laser-like focus.", "Bruce Lee"),
        ("It is during our darkest moments that we must focus to see the light.", "Aristotle"),
        ("Concentration is the secret of strength.", "Ralph Waldo Emerson"),
        ("Where focus goes, energy flows.", "Tony Robbins"),
        ("The mind is everything. What you think you become.", "Buddha"),
        ("Do not dwell in the past, do not dream of the future, concentrate the mind on the present moment.", "Buddha"),
        ("Starve your distractions, feed your focus.", "Daniel Goleman"),
        ("You will never reach your destination if you stop and throw stones at every dog that barks.", "Winston Churchill")
    ]

    var body: some View {
        ZStack {
            DS.mainGradient.ignoresSafeArea()
            GridBackground()
            ParticleView()
            ScanlineOverlay()

            ScrollView(showsIndicators:false) {
                VStack(spacing:20) {
                    headerSection
                    xpProgressSection
                    dailyGoalCard
                    statsCardsRow
                    streakCard
                    quoteCard
                    quickAccessSection
                    breathingCard
                    tipCard
                    recentSessionsSection
                }
                .padding(.horizontal,20)
                .padding(.top,60)
                .padding(.bottom,120)
            }

            VStack {
                HStack {
                    Spacer()
                    PressButton(action:{ showSettings = true }) {
                        Image(systemName:"gearshape.fill")
                            .font(.system(size:20))
                            .foregroundStyle(LinearGradient(colors:[DS.green, DS.cyan], startPoint:.topLeading, endPoint:.bottomTrailing))
                            .padding(12)
                            .background(Circle().fill(DS.cardBg).shadow(color:DS.green.opacity(0.3), radius:8))
                    }
                }.padding(.horizontal,20).padding(.top,50)
                Spacer()
            }
        }
        .fullScreenCover(isPresented:$showSettings) { SettingsView() }
        .fullScreenCover(isPresented:$showFocusTimer) { FocusTimerView() }
        .fullScreenCover(isPresented:$showBreathingExercise) { BreathingExerciseView() }
        .onAppear {
            withAnimation(.spring().delay(0.1)) { cardAppear = true }
            withAnimation(.easeInOut(duration:1.2).repeatForever(autoreverses:true)) { flameScale = 1.15 }
            tipIndex = Int.random(in:0..<tips.count)
            quoteIndex = Int.random(in:0..<quotes.count)
            withAnimation(.easeOut(duration:1.2).delay(0.3)) { goalRingProgress = appState.dailyGoalProgress }
        }
    }

    var headerSection: some View {
        HStack(alignment:.top) {
            VStack(alignment:.leading, spacing:4) {
                Text("HELLO,").font(.system(size:13,weight:.medium,design:.monospaced)).foregroundColor(DS.green.opacity(0.7))
                GlowingText(text:appState.userName.isEmpty ? "COMMANDER" : appState.userName.uppercased(),
                            font:.system(size:26,weight:.black,design:.monospaced), color:.white)
                Text("Level \(appState.currentLevel) • \(appState.totalXP) XP")
                    .font(.system(size:12,weight:.medium,design:.monospaced)).foregroundColor(DS.green.opacity(0.7))
            }
            Spacer()
            avatarView
        }
        .opacity(cardAppear ? 1 : 0)
        .offset(y:cardAppear ? 0 : 20)
    }

    var avatarView: some View {
        ZStack {
            Circle()
                .stroke(LinearGradient(colors:[DS.green, DS.cyan], startPoint:.topLeading, endPoint:.bottomTrailing), lineWidth:2)
                .frame(width:60,height:60)
            if let data = appState.userPhotoData, let img = UIImage(data:data) {
                Image(uiImage:img).resizable().scaledToFill().frame(width:56,height:56).clipShape(Circle())
            } else {
                Image(systemName:"person.fill").font(.title2)
                    .foregroundStyle(LinearGradient(colors:[DS.green,DS.cyan], startPoint:.topLeading, endPoint:.bottomTrailing))
                    .frame(width:56,height:56)
            }
        }
    }

    var statsCardsRow: some View {
        HStack(spacing:12) {
            miniStatCard(icon:"clock.fill", label:"Sessions", value:"\(appState.sessionHistory.count)", color:DS.cyan)
            miniStatCard(icon:"book.fill", label:"Lessons", value:"\(appState.lessonsCompleted.count)/12", color:DS.purple)
            miniStatCard(icon:"star.fill", label:"Level", value:"L\(appState.currentLevel)", color:DS.gold)
        }
        .opacity(cardAppear ? 1 : 0)
        .offset(y:cardAppear ? 0 : 20)
        .animation(.spring().delay(0.15), value:cardAppear)
    }

    func miniStatCard(icon:String, label:String, value:String, color:Color) -> some View {
        CyberCard(glowColor:color) {
            VStack(spacing:6) {
                Image(systemName:icon).font(.system(size:20))
                    .foregroundStyle(LinearGradient(colors:[color, color.opacity(0.6)], startPoint:.top, endPoint:.bottom))
                    .shadow(color:color.opacity(0.6), radius:4)
                Text(value).font(.system(size:18,weight:.black,design:.monospaced)).foregroundColor(.white)
                Text(label).font(.system(size:10,weight:.medium,design:.monospaced)).foregroundColor(.white.opacity(0.5))
            }.padding(.vertical,14).frame(maxWidth:.infinity)
        }
    }

    var streakCard: some View {
        CyberCard(glowColor:DS.red) {
            HStack(spacing:16) {
                Text("🔥").font(.system(size:44)).scaleEffect(flameScale)
                VStack(alignment:.leading, spacing:4) {
                    Text("CURRENT STREAK")
                        .font(.system(size:11,weight:.bold,design:.monospaced)).foregroundColor(DS.red.opacity(0.8))
                    HStack(alignment:.lastTextBaseline, spacing:4) {
                        Text("\(appState.currentStreak)")
                            .font(.system(size:36,weight:.black,design:.monospaced))
                            .foregroundStyle(LinearGradient(colors:[DS.red, DS.gold], startPoint:.leading, endPoint:.trailing))
                        Text("DAYS").font(.system(size:14,weight:.bold,design:.monospaced)).foregroundColor(.white.opacity(0.6))
                    }
                    Text(streakMessage).font(.system(size:12)).foregroundColor(.white.opacity(0.6))
                }
                Spacer()
            }.padding(18)
        }
        .opacity(cardAppear ? 1 : 0)
        .animation(.spring().delay(0.2), value:cardAppear)
    }

    var streakMessage: String {
        let s = appState.currentStreak
        if s == 0 { return "Start your streak today!" }
        if s < 3 { return "Keep it going — day \(s)!" }
        if s < 7 { return "Building momentum! 🚀" }
        if s < 30 { return "Week warrior! Outstanding! ⚡" }
        return "Iron mind. Legendary! 👑"
    }

    var tipCard: some View {
        CyberCard(glowColor:DS.greenMid) {
            HStack(alignment:.top, spacing:14) {
                Image(systemName:"lightbulb.max.fill").font(.title2)
                    .foregroundStyle(LinearGradient(colors:[DS.gold, DS.green], startPoint:.top, endPoint:.bottom))
                    .shadow(color:DS.gold.opacity(0.5), radius:4)
                VStack(alignment:.leading, spacing:6) {
                    Text("TIP OF THE DAY").font(.system(size:11,weight:.bold,design:.monospaced)).foregroundColor(DS.gold.opacity(0.8))
                    Text(tips[tipIndex]).font(.system(size:13,weight:.regular)).foregroundColor(.white.opacity(0.85)).fixedSize(horizontal:false, vertical:true)
                }
            }.padding(16)
        }
        .opacity(cardAppear ? 1 : 0)
        .animation(.spring().delay(0.25), value:cardAppear)
    }

    var quickAccessSection: some View {
        VStack(alignment:.leading, spacing:12) {
            Text("QUICK ACCESS").font(.system(size:12,weight:.bold,design:.monospaced)).foregroundColor(DS.green.opacity(0.7))
            PressButton(action:{ showFocusTimer = true }) {
                CyberCard(glowColor:DS.green) {
                    HStack(spacing:16) {
                        ZStack {
                            Circle().fill(DS.green.opacity(0.15)).frame(width:52,height:52)
                            Image(systemName:"timer").font(.title2)
                                .foregroundStyle(LinearGradient(colors:[DS.green, DS.cyan], startPoint:.topLeading, endPoint:.bottomTrailing))
                        }
                        VStack(alignment:.leading, spacing:3) {
                            Text("FOCUS TIMER").font(.system(size:15,weight:.black,design:.monospaced)).foregroundColor(.white)
                            Text("Launch a focused deep work session").font(.system(size:12)).foregroundColor(.white.opacity(0.6))
                        }
                        Spacer()
                        Image(systemName:"chevron.right").foregroundColor(DS.green.opacity(0.7))
                    }.padding(16)
                }
            }
        }
        .opacity(cardAppear ? 1 : 0)
        .animation(.spring().delay(0.3), value:cardAppear)
    }

    // MARK: - XP Progress Section
    var xpProgressSection: some View {
        CyberCard(glowColor:DS.green) {
            VStack(spacing:10) {
                HStack {
                    HStack(spacing:6) {
                        Image(systemName:"bolt.circle.fill").font(.system(size:16))
                            .foregroundStyle(LinearGradient(colors:[DS.green, DS.cyan], startPoint:.topLeading, endPoint:.bottomTrailing))
                        Text("LEVEL \(appState.currentLevel)")
                            .font(.system(size:14, weight:.black, design:.monospaced))
                            .foregroundStyle(LinearGradient(colors:[DS.green, DS.cyan], startPoint:.leading, endPoint:.trailing))
                    }
                    Spacer()
                    Text("\(appState.totalXP) / \(appState.xpForNextLevel()) XP")
                        .font(.system(size:12, weight:.bold, design:.monospaced))
                        .foregroundColor(DS.gold)
                }
                XPBar(progress:appState.xpProgress(), color:DS.green)
                HStack {
                    Text("\(appState.xpForNextLevel() - appState.totalXP) XP to next level")
                        .font(.system(size:11, design:.monospaced)).foregroundColor(.white.opacity(0.5))
                    Spacer()
                }
            }.padding(16)
        }
        .opacity(cardAppear ? 1 : 0)
        .offset(y:cardAppear ? 0 : 20)
        .animation(.spring().delay(0.12), value:cardAppear)
    }

    // MARK: - Daily Goal Card
    var dailyGoalCard: some View {
        CyberCard(glowColor: appState.todaySessionCount >= appState.dailyGoalSessions ? DS.gold : DS.cyan) {
            HStack(spacing:18) {
                ZStack {
                    Circle()
                        .stroke(Color.white.opacity(0.08), lineWidth:8)
                        .frame(width:72, height:72)
                    Circle()
                        .trim(from:0, to:goalRingProgress)
                        .stroke(
                            LinearGradient(colors: appState.todaySessionCount >= appState.dailyGoalSessions ? [DS.gold, DS.green] : [DS.cyan, DS.green],
                                           startPoint:.topLeading, endPoint:.bottomTrailing),
                            style:StrokeStyle(lineWidth:8, lineCap:.round)
                        )
                        .frame(width:72, height:72)
                        .rotationEffect(.degrees(-90))
                        .shadow(color:(appState.todaySessionCount >= appState.dailyGoalSessions ? DS.gold : DS.cyan).opacity(0.5), radius:6)
                    VStack(spacing:0) {
                        Text("\(appState.todaySessionCount)")
                            .font(.system(size:22, weight:.black, design:.monospaced))
                            .foregroundColor(.white)
                        Text("/\(appState.dailyGoalSessions)")
                            .font(.system(size:11, weight:.bold, design:.monospaced))
                            .foregroundColor(.white.opacity(0.5))
                    }
                }
                VStack(alignment:.leading, spacing:6) {
                    Text("DAILY GOAL")
                        .font(.system(size:11, weight:.bold, design:.monospaced))
                        .foregroundColor(DS.cyan.opacity(0.8))
                    if appState.todaySessionCount >= appState.dailyGoalSessions {
                        Text("Goal reached!")
                            .font(.system(size:16, weight:.black, design:.monospaced))
                            .foregroundStyle(LinearGradient(colors:[DS.gold, DS.green], startPoint:.leading, endPoint:.trailing))
                        Text("You've crushed today's target")
                            .font(.system(size:12)).foregroundColor(.white.opacity(0.6))
                    } else {
                        Text("\(appState.dailyGoalSessions - appState.todaySessionCount) sessions left")
                            .font(.system(size:16, weight:.black, design:.monospaced))
                            .foregroundColor(.white)
                        Text("Complete focus sessions to hit your goal")
                            .font(.system(size:12)).foregroundColor(.white.opacity(0.6))
                    }
                }
                Spacer()
            }.padding(16)
        }
        .opacity(cardAppear ? 1 : 0)
        .offset(y:cardAppear ? 0 : 20)
        .animation(.spring().delay(0.13), value:cardAppear)
    }

    // MARK: - Quote Card
    var quoteCard: some View {
        CyberCard(glowColor:DS.purple) {
            VStack(spacing:12) {
                HStack {
                    Image(systemName:"quote.opening").font(.system(size:22))
                        .foregroundStyle(LinearGradient(colors:[DS.purple, DS.cyan], startPoint:.topLeading, endPoint:.bottomTrailing))
                        .shadow(color:DS.purple.opacity(0.5), radius:4)
                    Spacer()
                    PressButton(action:{
                        withAnimation(.spring()) {
                            quoteIndex = (quoteIndex + 1) % quotes.count
                        }
                    }) {
                        Image(systemName:"arrow.triangle.2.circlepath")
                            .font(.system(size:14, weight:.bold))
                            .foregroundColor(DS.purple.opacity(0.7))
                            .padding(8)
                            .background(Circle().fill(DS.cardBg))
                    }
                }
                Text("\"\(quotes[quoteIndex].text)\"")
                    .font(.system(size:15, weight:.medium, design:.serif))
                    .foregroundColor(.white.opacity(0.9))
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal:false, vertical:true)
                    .id(quoteIndex)
                    .transition(.opacity.combined(with:.scale(scale:0.95)))
                Text("— \(quotes[quoteIndex].author)")
                    .font(.system(size:12, weight:.semibold, design:.monospaced))
                    .foregroundColor(DS.purple.opacity(0.7))
                    .id("author-\(quoteIndex)")
                    .transition(.opacity)
            }.padding(18)
        }
        .opacity(cardAppear ? 1 : 0)
        .animation(.spring().delay(0.22), value:cardAppear)
    }

    // MARK: - Breathing Exercise Card
    var breathingCard: some View {
        PressButton(action:{ showBreathingExercise = true }) {
            CyberCard(glowColor:Color(red:0.2, green:0.7, blue:0.9)) {
                HStack(spacing:16) {
                    ZStack {
                        Circle().fill(Color(red:0.2,green:0.7,blue:0.9).opacity(0.15)).frame(width:52,height:52)
                        Image(systemName:"wind").font(.title2)
                            .foregroundStyle(LinearGradient(colors:[Color(red:0.2,green:0.7,blue:0.9), DS.cyan], startPoint:.topLeading, endPoint:.bottomTrailing))
                            .shadow(color:Color(red:0.2,green:0.7,blue:0.9).opacity(0.5), radius:4)
                    }
                    VStack(alignment:.leading, spacing:3) {
                        Text("BREATHING EXERCISE").font(.system(size:15,weight:.black,design:.monospaced)).foregroundColor(.white)
                        Text("Calm your mind before deep work").font(.system(size:12)).foregroundColor(.white.opacity(0.6))
                    }
                    Spacer()
                    Image(systemName:"chevron.right").foregroundColor(Color(red:0.2,green:0.7,blue:0.9).opacity(0.7))
                }.padding(16)
            }
        }
        .opacity(cardAppear ? 1 : 0)
        .animation(.spring().delay(0.32), value:cardAppear)
    }

    // MARK: - Recent Sessions Section
    var recentSessionsSection: some View {
        VStack(alignment:.leading, spacing:12) {
            Text("RECENT ACTIVITY").font(.system(size:12,weight:.bold,design:.monospaced)).foregroundColor(DS.green.opacity(0.7))
            if appState.sessionHistory.isEmpty {
                CyberCard(glowColor:DS.green.opacity(0.2)) {
                    HStack(spacing:12) {
                        Image(systemName:"clock.badge.questionmark").font(.title3).foregroundColor(DS.green.opacity(0.4))
                        Text("No sessions yet. Start a focus timer or take a quiz to see your activity here.")
                            .font(.system(size:13)).foregroundColor(.white.opacity(0.5))
                    }.padding(16)
                }
            } else {
                ForEach(appState.sessionHistory.suffix(3).reversed()) { session in
                    CyberCard(glowColor:session.sessionType == "Quiz" ? DS.purple.opacity(0.5) : DS.green.opacity(0.4)) {
                        HStack(spacing:12) {
                            ZStack {
                                Circle().fill((session.sessionType == "Quiz" ? DS.purple : DS.green).opacity(0.15)).frame(width:38,height:38)
                                Image(systemName:session.sessionType == "Quiz" ? "brain.head.profile" : session.sessionType == "Breathing" ? "wind" : "timer")
                                    .font(.system(size:16))
                                    .foregroundColor(session.sessionType == "Quiz" ? DS.purple : DS.green)
                            }
                            VStack(alignment:.leading, spacing:2) {
                                Text(session.sessionType).font(.system(size:13,weight:.bold,design:.monospaced)).foregroundColor(.white)
                                Text(session.date, style:.relative).font(.system(size:11,design:.monospaced)).foregroundColor(.white.opacity(0.4))
                            }
                            Spacer()
                            Text("+\(session.xpEarned) XP").font(.system(size:12,weight:.bold,design:.monospaced)).foregroundColor(DS.gold)
                        }.padding(12)
                    }
                }
            }
        }
        .opacity(cardAppear ? 1 : 0)
        .animation(.spring().delay(0.35), value:cardAppear)
    }
}

// MARK: - Breathing Exercise View
struct BreathingExerciseView: View {
    @EnvironmentObject var appState: AppState
    @Environment(\.dismiss) var dismiss
    @State private var phase: BreathPhase = .inhale
    @State private var circleScale: CGFloat = 0.5
    @State private var circleOpacity: Double = 0.4
    @State private var isActive = false
    @State private var cyclesCompleted = 0
    @State private var totalCycles = 4
    @State private var sessionDone = false
    @State private var phaseTimer: Timer? = nil
    @State private var countDown = 4

    enum BreathPhase: String {
        case inhale = "BREATHE IN"
        case hold = "HOLD"
        case exhale = "BREATHE OUT"
        case rest = "REST"

        var duration: Int {
            switch self {
            case .inhale: return 4
            case .hold: return 4
            case .exhale: return 4
            case .rest: return 4
            }
        }

        var next: BreathPhase {
            switch self {
            case .inhale: return .hold
            case .hold: return .exhale
            case .exhale: return .rest
            case .rest: return .inhale
            }
        }
    }

    var phaseColor: Color {
        switch phase {
        case .inhale: return DS.cyan
        case .hold: return DS.purple
        case .exhale: return DS.green
        case .rest: return DS.gold
        }
    }

    var body: some View {
        ZStack {
            DS.mainGradient.ignoresSafeArea()
            GridBackground()
            ScanlineOverlay()

            VStack(spacing:28) {
                HStack {
                    PressButton(action:{ stopSession(); dismiss() }) {
                        Image(systemName:"xmark").font(.title3).foregroundColor(.white.opacity(0.7)).padding(14)
                            .background(Circle().fill(DS.cardBg))
                    }
                    Spacer()
                    GlowingText(text:"BREATHE", font:.system(size:16,weight:.black,design:.monospaced), color:DS.cyan)
                    Spacer()
                    Circle().fill(Color.clear).frame(width:44,height:44)
                }.padding(.horizontal,20).padding(.top,50)

                if sessionDone {
                    sessionCompleteView
                } else if !isActive {
                    breathingIntroView
                } else {
                    breathingActiveView
                }

                Spacer()
            }
        }
    }

    var breathingIntroView: some View {
        VStack(spacing:28) {
            Spacer()
            ZStack {
                ForEach(0..<3) { i in
                    Circle().stroke(DS.cyan.opacity(0.15 - Double(i)*0.04), lineWidth:1)
                        .frame(width:CGFloat(120+i*40), height:CGFloat(120+i*40))
                }
                Image(systemName:"wind").font(.system(size:56))
                    .foregroundStyle(LinearGradient(colors:[DS.cyan, DS.green], startPoint:.topLeading, endPoint:.bottomTrailing))
                    .shadow(color:DS.cyan.opacity(0.7), radius:16)
            }
            VStack(spacing:10) {
                GlowingText(text:"BOX BREATHING", font:.system(size:26,weight:.black,design:.monospaced), color:DS.cyan)
                Text("4-4-4-4 breathing pattern used by\nNavy SEALs to control stress response")
                    .font(.system(size:14,weight:.medium,design:.monospaced)).foregroundColor(.white.opacity(0.7))
                    .multilineTextAlignment(.center)
            }
            VStack(spacing:10) {
                breathInfoRow("4 sec inhale through nose")
                breathInfoRow("4 sec hold at the top")
                breathInfoRow("4 sec exhale through mouth")
                breathInfoRow("4 sec rest before repeat")
            }.padding(.horizontal,40)
            Text("\(totalCycles) cycles • ~1 min")
                .font(.system(size:13,design:.monospaced)).foregroundColor(.white.opacity(0.5))
            Spacer()
            PressButton(action:{ startSession() }) {
                Text("BEGIN").font(.system(size:17,weight:.black,design:.monospaced)).foregroundColor(.black)
                    .frame(maxWidth:.infinity).padding(.vertical,18)
                    .background(LinearGradient(colors:[DS.cyan, DS.green], startPoint:.leading, endPoint:.trailing))
                    .clipShape(RoundedRectangle(cornerRadius:18))
                    .shadow(color:DS.cyan.opacity(0.5), radius:12)
            }.padding(.horizontal,28).padding(.bottom,40)
        }
    }

    func breathInfoRow(_ text: String) -> some View {
        HStack(spacing:10) {
            Circle().fill(DS.cyan.opacity(0.8)).frame(width:6,height:6)
            Text(text).font(.system(size:13,design:.monospaced)).foregroundColor(.white.opacity(0.8))
            Spacer()
        }
    }

    var breathingActiveView: some View {
        VStack(spacing:32) {
            Text("Cycle \(cyclesCompleted + 1) / \(totalCycles)")
                .font(.system(size:14,weight:.bold,design:.monospaced)).foregroundColor(.white.opacity(0.6))

            ZStack {
                Circle()
                    .fill(phaseColor.opacity(0.08))
                    .frame(width:260, height:260)
                Circle()
                    .stroke(phaseColor.opacity(0.3), lineWidth:2)
                    .frame(width:260, height:260)
                Circle()
                    .fill(RadialGradient(colors:[phaseColor.opacity(0.4), phaseColor.opacity(0.05)], center:.center, startRadius:10, endRadius:130))
                    .frame(width:260, height:260)
                    .scaleEffect(circleScale)
                    .opacity(circleOpacity)
                    .shadow(color:phaseColor.opacity(0.6), radius:20)

                VStack(spacing:8) {
                    Text(phase.rawValue)
                        .font(.system(size:20,weight:.black,design:.monospaced))
                        .foregroundColor(phaseColor)
                        .shadow(color:phaseColor.opacity(0.7), radius:8)
                    Text("\(countDown)")
                        .font(.system(size:48,weight:.black,design:.monospaced))
                        .foregroundColor(.white)
                }
            }

            HStack(spacing:16) {
                ForEach(0..<totalCycles, id:\.self) { i in
                    Circle()
                        .fill(i < cyclesCompleted ? DS.green : (i == cyclesCompleted ? phaseColor : Color.white.opacity(0.15)))
                        .frame(width:12, height:12)
                        .shadow(color:i < cyclesCompleted ? DS.green.opacity(0.6) : Color.clear, radius:4)
                }
            }
        }
    }

    var sessionCompleteView: some View {
        VStack(spacing:24) {
            Spacer()
            ZStack {
                ForEach(0..<3) { i in
                    Circle().stroke(DS.green.opacity(0.15 - Double(i)*0.04), lineWidth:1)
                        .frame(width:CGFloat(100+i*40), height:CGFloat(100+i*40))
                }
                Image(systemName:"checkmark.circle.fill").font(.system(size:64))
                    .foregroundStyle(LinearGradient(colors:[DS.green, DS.cyan], startPoint:.topLeading, endPoint:.bottomTrailing))
                    .shadow(color:DS.green.opacity(0.8), radius:16)
            }
            VStack(spacing:8) {
                GlowingText(text:"SESSION COMPLETE", font:.system(size:22,weight:.black,design:.monospaced), color:DS.green)
                Text("+15 XP earned").font(.system(size:15,weight:.bold,design:.monospaced)).foregroundColor(DS.gold)
                Text("Your mind is primed for deep work")
                    .font(.system(size:13)).foregroundColor(.white.opacity(0.6))
            }
            Spacer()
            PressButton(action:{ dismiss() }) {
                Text("DONE").font(.system(size:16,weight:.black,design:.monospaced)).foregroundColor(.black)
                    .frame(maxWidth:.infinity).padding(.vertical,16)
                    .background(DS.greenGradient).clipShape(RoundedRectangle(cornerRadius:16))
                    .shadow(color:DS.green.opacity(0.5), radius:12)
            }.padding(.horizontal,28).padding(.bottom,40)
        }
    }

    func startSession() {
        isActive = true
        phase = .inhale
        cyclesCompleted = 0
        startPhase()
    }

    func startPhase() {
        countDown = phase.duration
        animateCircle()
        phaseTimer?.invalidate()
        phaseTimer = Timer.scheduledTimer(withTimeInterval:1, repeats:true) { _ in
            if countDown > 1 {
                countDown -= 1
            } else {
                advancePhase()
            }
        }
    }

    func animateCircle() {
        switch phase {
        case .inhale:
            withAnimation(.easeInOut(duration:Double(phase.duration))) {
                circleScale = 1.0; circleOpacity = 0.8
            }
        case .hold:
            withAnimation(.easeInOut(duration:0.3)) {
                circleScale = 1.0; circleOpacity = 0.9
            }
        case .exhale:
            withAnimation(.easeInOut(duration:Double(phase.duration))) {
                circleScale = 0.5; circleOpacity = 0.3
            }
        case .rest:
            withAnimation(.easeInOut(duration:0.3)) {
                circleScale = 0.5; circleOpacity = 0.25
            }
        }
    }

    func advancePhase() {
        phaseTimer?.invalidate()
        let nextPhase = phase.next
        if nextPhase == .inhale {
            cyclesCompleted += 1
            if cyclesCompleted >= totalCycles {
                completeSession()
                return
            }
        }
        withAnimation(.spring()) { phase = nextPhase }
        startPhase()
    }

    func completeSession() {
        phaseTimer?.invalidate()
        isActive = false
        sessionDone = true
        let record = SessionRecord(date:Date(), score:totalCycles, xpEarned:15, duration:totalCycles*16, sessionType:"Breathing")
        appState.addSession(record)
        appState.addXP(15)
        UINotificationFeedbackGenerator().notificationOccurred(.success)
    }

    func stopSession() {
        phaseTimer?.invalidate()
        phaseTimer = nil
    }
}

// MARK: - Focus Timer
struct FocusTimerView: View {
    @EnvironmentObject var appState: AppState
    @Environment(\.dismiss) var dismiss
    @State private var totalSeconds: Int = 1500
    @State private var remaining: Int = 1500
    @State private var isRunning = false
    @State private var completed = false
    @State private var selectedMode = 0
    @State private var timer: Timer? = nil
    @State private var progressScale: CGFloat = 1.0
    let modes = [("Focus", 1500), ("Short Break", 300), ("Long Break", 900), ("Deep Work", 5400)]

    var progress: Double { 1.0 - Double(remaining) / Double(totalSeconds) }

    var body: some View {
        ZStack {
            DS.mainGradient.ignoresSafeArea()
            GridBackground()
            ParticleView()
            ScanlineOverlay()

            VStack(spacing:28) {
                HStack {
                    PressButton(action:{ stopTimer(); dismiss() }) {
                        Image(systemName:"xmark").font(.title3).foregroundColor(.white.opacity(0.7)).padding(14)
                            .background(Circle().fill(DS.cardBg))
                    }
                    Spacer()
                    GlowingText(text:"FOCUS TIMER", font:.system(size:16,weight:.black,design:.monospaced), color:DS.green)
                    Spacer()
                    Circle().fill(Color.clear).frame(width:44,height:44)
                }.padding(.horizontal,20).padding(.top,50)

                ScrollView(.horizontal, showsIndicators:false) {
                    HStack(spacing:10) {
                        ForEach(0..<modes.count, id:\.self) { i in
                            PressButton(action:{ selectMode(i) }) {
                                Text(modes[i].0).font(.system(size:13,weight:.bold,design:.monospaced))
                                    .foregroundColor(selectedMode==i ? .black : DS.green.opacity(0.7))
                                    .padding(.horizontal,16).padding(.vertical,8)
                                    .background(selectedMode==i ? DS.greenGradient : LinearGradient(colors:[DS.cardBg], startPoint:.leading, endPoint:.trailing))
                                    .clipShape(Capsule())
                                    .overlay(Capsule().stroke(DS.green.opacity(0.4), lineWidth:1))
                            }
                        }
                    }.padding(.horizontal,20)
                }

                ZStack {
                    Circle().stroke(DS.green.opacity(0.1), lineWidth:16).frame(width:260,height:260)
                    Circle().trim(from:0, to:progress)
                        .stroke(LinearGradient(colors:[DS.green, DS.cyan], startPoint:.topLeading, endPoint:.bottomTrailing), style:StrokeStyle(lineWidth:16, lineCap:.round))
                        .frame(width:260,height:260)
                        .rotationEffect(.degrees(-90))
                        .animation(.linear(duration:1), value:progress)
                        .shadow(color:DS.green.opacity(0.5), radius:8)
                    Circle().fill(DS.cardBg.opacity(0.8)).frame(width:220,height:220)

                    VStack(spacing:4) {
                        Text(timeString(remaining))
                            .font(.system(size:54,weight:.black,design:.monospaced))
                            .foregroundStyle(LinearGradient(colors:[DS.green, DS.cyan], startPoint:.leading, endPoint:.trailing))
                            .shadow(color:DS.green.opacity(0.5), radius:8)
                        Text(modes[selectedMode].0.uppercased())
                            .font(.system(size:12,weight:.bold,design:.monospaced)).foregroundColor(.white.opacity(0.5))
                    }
                }
                .scaleEffect(progressScale)

                HStack(spacing:24) {
                    PressButton(action:{ resetTimer() }) {
                        Image(systemName:"arrow.counterclockwise").font(.title2).foregroundColor(.white.opacity(0.7)).padding(18)
                            .background(Circle().fill(DS.cardBg).shadow(color:DS.green.opacity(0.2), radius:8))
                    }
                    PressButton(action:{ toggleTimer() }) {
                        ZStack {
                            Circle().fill(isRunning ? DS.red.opacity(0.2) : DS.green.opacity(0.2)).frame(width:80,height:80)
                            Circle().stroke(isRunning ? DS.red : DS.green, lineWidth:2).frame(width:80,height:80)
                            Image(systemName:isRunning ? "pause.fill" : "play.fill").font(.title)
                                .foregroundStyle(isRunning ? AnyShapeStyle(DS.red) : AnyShapeStyle(LinearGradient(colors:[DS.green,DS.cyan], startPoint:.topLeading, endPoint:.bottomTrailing)))
                        }
                    }
                    PressButton(action:{ skipTimer() }) {
                        Image(systemName:"forward.end.fill").font(.title2).foregroundColor(.white.opacity(0.7)).padding(18)
                            .background(Circle().fill(DS.cardBg).shadow(color:DS.green.opacity(0.2), radius:8))
                    }
                }

                if completed {
                    CyberCard(glowColor:DS.gold) {
                        HStack(spacing:12) {
                            Text("🎉").font(.title)
                            VStack(alignment:.leading) {
                                Text("SESSION COMPLETE!").font(.system(size:14,weight:.black,design:.monospaced)).foregroundColor(DS.gold)
                                Text("+20 XP earned").font(.system(size:12,design:.monospaced)).foregroundColor(.white.opacity(0.7))
                            }
                        }.padding(16)
                    }.padding(.horizontal,20)
                }

                Spacer()
            }
        }
        .onDisappear { stopTimer() }
    }

    func selectMode(_ i: Int) {
        selectedMode = i; stopTimer()
        totalSeconds = modes[i].1; remaining = modes[i].1; completed = false
    }

    func toggleTimer() {
        if isRunning { stopTimer() } else { startTimer() }
    }

    func startTimer() {
        isRunning = true
        timer = Timer.scheduledTimer(withTimeInterval:1, repeats:true) { _ in
            if remaining > 0 { remaining -= 1 }
            else { completeSession() }
        }
        withAnimation(.easeInOut(duration:0.8).repeatForever(autoreverses:true)) { progressScale = 1.02 }
    }

    func stopTimer() {
        isRunning = false; timer?.invalidate(); timer = nil
        withAnimation { progressScale = 1.0 }
    }

    func resetTimer() {
        stopTimer(); remaining = totalSeconds; completed = false
    }

    func skipTimer() { completeSession() }

    func completeSession() {
        stopTimer(); completed = true
        let record = SessionRecord(date:Date(), score:100, xpEarned:20, duration:totalSeconds - remaining, sessionType:"Focus Timer")
        appState.addSession(record)
        appState.addXP(20)
        UINotificationFeedbackGenerator().notificationOccurred(.success)
    }

    func timeString(_ s: Int) -> String {
        let m = s/60; let sec = s%60
        return String(format:"%02d:%02d", m, sec)
    }
}

// MARK: - Lessons View
struct LessonsView: View {
    @EnvironmentObject var appState: AppState
    @State private var selectedLesson: Lesson? = nil
    @State private var filterDifficulty = "All"
    @State private var sortByXP = false
    @State private var gridAppear = false

    let filters = ["All","Beginner","Intermediate","Advanced"]

    var filtered: [Lesson] {
        var lessons = DataSeed.lessons
        if filterDifficulty != "All" { lessons = lessons.filter { $0.difficulty == filterDifficulty } }
        if sortByXP { lessons = lessons.sorted { $0.xpReward > $1.xpReward } }
        return lessons
    }

    var body: some View {
        ZStack {
            DS.mainGradient.ignoresSafeArea()
            GridBackground()
            ScanlineOverlay()

            VStack(spacing:0) {
                headerBar
                filterBar
                ScrollView(showsIndicators:false) {
                    LazyVGrid(columns:[GridItem(.flexible()),GridItem(.flexible())], spacing:14) {
                        ForEach(Array(filtered.enumerated()), id:\.element.id) { idx, lesson in
                            PressButton(action:{ selectedLesson = lesson }) {
                                lessonCard(lesson, idx:idx)
                            }
                        }
                    }
                    .padding(.horizontal,20)
                    .padding(.top,12)
                    .padding(.bottom,120)
                }
            }
        }
        .fullScreenCover(item:$selectedLesson) { lesson in LessonDetailView(lesson:lesson) }
    }

    var headerBar: some View {
        HStack {
            VStack(alignment:.leading, spacing:2) {
                GlowingText(text:"KNOWLEDGE BASE", font:.system(size:20,weight:.black,design:.monospaced), color:DS.green)
                Text("\(appState.lessonsCompleted.count)/12 completed").font(.system(size:12,design:.monospaced)).foregroundColor(DS.green.opacity(0.6))
            }
            Spacer()
            PressButton(action:{ withAnimation(.spring()) { sortByXP.toggle() } }) {
                Image(systemName:"arrow.up.arrow.down").font(.system(size:16))
                    .foregroundColor(sortByXP ? DS.green : .white.opacity(0.5)).padding(10)
                    .background(RoundedRectangle(cornerRadius:10).fill(DS.cardBg))
            }
        }.padding(.horizontal,20).padding(.top,60).padding(.bottom,12)
    }

    var filterBar: some View {
        ScrollView(.horizontal, showsIndicators:false) {
            HStack(spacing:10) {
                ForEach(filters, id:\.self) { f in
                    PressButton(action:{ withAnimation(.spring()) { filterDifficulty = f } }) {
                        Text(f).font(.system(size:13,weight:.bold,design:.monospaced))
                            .foregroundColor(filterDifficulty==f ? .black : .white.opacity(0.6))
                            .padding(.horizontal,16).padding(.vertical,8)
                            .background(filterDifficulty==f ? DS.greenGradient : LinearGradient(colors:[DS.cardBg], startPoint:.leading, endPoint:.trailing))
                            .clipShape(Capsule())
                            .overlay(Capsule().stroke(DS.green.opacity(0.3), lineWidth:1))
                    }
                }
            }.padding(.horizontal,20)
        }.padding(.bottom,8)
    }

    func lessonCard(_ lesson: Lesson, idx: Int) -> some View {
        let done = appState.lessonsCompleted.contains(lesson.id)
        return CyberCard(glowColor:done ? DS.green : lesson.difficultyColor.opacity(0.6)) {
            VStack(alignment:.leading, spacing:10) {
                HStack {
                    Image(systemName:lesson.icon).font(.title2)
                        .foregroundStyle(LinearGradient(colors:[done ? DS.green : lesson.difficultyColor, DS.cyan], startPoint:.topLeading, endPoint:.bottomTrailing))
                        .shadow(color:(done ? DS.green : lesson.difficultyColor).opacity(0.5), radius:4)
                    Spacer()
                    if done {
                        Image(systemName:"checkmark.circle.fill").foregroundColor(DS.green)
                            .font(.system(size:18)).shadow(color:DS.green.opacity(0.7), radius:4)
                    }
                }
                Text(lesson.title).font(.system(size:13,weight:.bold,design:.monospaced)).foregroundColor(.white).lineLimit(2).fixedSize(horizontal:false,vertical:true)
                Text(lesson.description).font(.system(size:11)).foregroundColor(.white.opacity(0.6)).lineLimit(2).fixedSize(horizontal:false,vertical:true)
                HStack(spacing:6) {
                    Text(lesson.difficulty).font(.system(size:10,weight:.bold,design:.monospaced))
                        .foregroundColor(lesson.difficultyColor).padding(.horizontal,8).padding(.vertical,3)
                        .background(RoundedRectangle(cornerRadius:6).fill(lesson.difficultyColor.opacity(0.15)))
                    Spacer()
                    Text("+\(lesson.xpReward)XP").font(.system(size:10,weight:.bold,design:.monospaced)).foregroundColor(DS.gold)
                }
            }.padding(14)
        }
        .opacity(gridAppear ? 1 : 0)
        .offset(y:gridAppear ? 0 : 20)
        .animation(.spring().delay(Double(idx)*0.05), value:gridAppear)
        .onAppear { if !gridAppear { withAnimation { gridAppear = true } } }
    }
}

struct LessonDetailView: View {
    @EnvironmentObject var appState: AppState
    @Environment(\.dismiss) var dismiss
    let lesson: Lesson
    @State private var scrollOffset: CGFloat = 0
    @State private var showComplete = false
    @State private var justCompleted = false
    let isCompleted: Bool

    init(lesson: Lesson) {
        self.lesson = lesson
        self.isCompleted = AppState.shared.lessonsCompleted.contains(lesson.id)
    }

    var body: some View {
        ZStack {
            DS.mainGradient.ignoresSafeArea()
            GridBackground()
            ScanlineOverlay()

            ScrollView(showsIndicators:false) {
                VStack(alignment:.leading, spacing:20) {
                    HStack {
                        PressButton(action:{ dismiss() }) {
                            Image(systemName:"xmark").font(.title3).foregroundColor(.white.opacity(0.7)).padding(14)
                                .background(Circle().fill(DS.cardBg))
                        }
                        Spacer()
                        HStack(spacing:6) {
                            Image(systemName:"star.fill").foregroundColor(DS.gold)
                            Text("+\(lesson.xpReward) XP").font(.system(size:14,weight:.bold,design:.monospaced)).foregroundColor(DS.gold)
                        }
                    }.padding(.horizontal,20).padding(.top,50)

                    VStack(alignment:.leading, spacing:12) {
                        Image(systemName:lesson.icon).font(.system(size:48))
                            .foregroundStyle(LinearGradient(colors:[DS.green, DS.cyan], startPoint:.topLeading, endPoint:.bottomTrailing))
                            .shadow(color:DS.green.opacity(0.6), radius:12)
                            .padding(.horizontal,20)

                        VStack(alignment:.leading, spacing:8) {
                            Text(lesson.title).font(.system(size:26,weight:.black,design:.monospaced)).foregroundColor(.white).padding(.horizontal,20)
                            HStack(spacing:10) {
                                Text(lesson.difficulty).font(.system(size:12,weight:.bold,design:.monospaced))
                                    .foregroundColor(lesson.difficultyColor).padding(.horizontal,10).padding(.vertical,5)
                                    .background(RoundedRectangle(cornerRadius:8).fill(lesson.difficultyColor.opacity(0.15)))
                                Text(lesson.description).font(.system(size:13)).foregroundColor(.white.opacity(0.7))
                            }.padding(.horizontal,20)
                        }

                        CyberCard(glowColor:DS.green) {
                            Text(lesson.content)
                                .font(.system(size:15, weight:.regular, design:.rounded))
                                .foregroundColor(.white.opacity(0.9))
                                .lineSpacing(7)
                                .padding(20)
                        }.padding(.horizontal,20)

                        if appState.lessonsCompleted.contains(lesson.id) || justCompleted {
                            CyberCard(glowColor:DS.green) {
                                HStack(spacing:12) {
                                    Image(systemName:"checkmark.seal.fill").font(.title).foregroundColor(DS.green).shadow(color:DS.green, radius:8)
                                    VStack(alignment:.leading) {
                                        Text("LESSON COMPLETE").font(.system(size:14,weight:.black,design:.monospaced)).foregroundColor(DS.green)
                                        Text("+\(lesson.xpReward) XP earned").font(.system(size:12,design:.monospaced)).foregroundColor(.white.opacity(0.7))
                                    }
                                }.padding(16)
                            }.padding(.horizontal,20)
                        } else {
                            PressButton(action:{ markComplete() }) {
                                HStack {
                                    Image(systemName:"checkmark.circle.fill").font(.title3)
                                    Text("MARK COMPLETE  +\(lesson.xpReward) XP")
                                        .font(.system(size:15,weight:.black,design:.monospaced))
                                }
                                .foregroundColor(.black).frame(maxWidth:.infinity).padding(.vertical,16)
                                .background(DS.greenGradient).clipShape(RoundedRectangle(cornerRadius:16))
                                .shadow(color:DS.green.opacity(0.5), radius:12)
                            }.padding(.horizontal,20)
                        }
                    }
                }.padding(.bottom,80)
            }
        }
    }

    func markComplete() {
        justCompleted = true
        appState.completeLesson(lesson.id)
        UINotificationFeedbackGenerator().notificationOccurred(.success)
    }
}

// MARK: - Quiz View
struct QuizView: View {
    @EnvironmentObject var appState: AppState
    @State private var quizStarted = false
    @State private var currentQ = 0
    @State private var score = 0
    @State private var selectedAnswer: String? = nil
    @State private var showResult = false
    @State private var isCorrect = false
    @State private var timeLeft: Int = 20
    @State private var timer: Timer? = nil
    @State private var shakeOffset: CGFloat = 0
    @State private var flashColor: Color = .clear
    @State private var showFlash = false
    @State private var quizComplete = false
    @State private var xpEarned = 0
    @State private var showSpriteKit = false
    @State private var progressAnim: Double = 1.0

    var questions: [QuizQuestion] { DataSeed.questions.shuffled() }
    @State private var shuffledQ: [QuizQuestion] = []
    var currentQuestion: QuizQuestion? { shuffledQ.isEmpty ? nil : shuffledQ[min(currentQ, shuffledQ.count-1)] }
    var timerProgress: Double { Double(timeLeft) / 20.0 }

    var body: some View {
        ZStack {
            DS.mainGradient.ignoresSafeArea()
            GridBackground()
            ScanlineOverlay()

            if !quizStarted && !quizComplete {
                quizIntroView
            } else if quizComplete {
                quizResultView
            } else if let q = currentQuestion {
                quizActiveView(q)
            }

            if showFlash {
                flashColor.opacity(0.25).ignoresSafeArea().allowsHitTesting(false)
                    .transition(.opacity)
            }
        }
        .fullScreenCover(isPresented:$showSpriteKit) { SpriteKitGameView() }
    }

    var quizIntroView: some View {
        VStack(spacing:28) {
            Spacer()
            ZStack {
                ForEach(0..<3) { i in
                    Circle().stroke(DS.purple.opacity(0.2 - Double(i)*0.06), lineWidth:1)
                        .frame(width:CGFloat(120+i*40), height:CGFloat(120+i*40))
                }
                Image(systemName:"brain.filled.head.profile").font(.system(size:60))
                    .foregroundStyle(LinearGradient(colors:[DS.purple, DS.cyan], startPoint:.topLeading, endPoint:.bottomTrailing))
                    .shadow(color:DS.purple.opacity(0.7), radius:16)
            }
            VStack(spacing:10) {
                GlowingText(text:"FOCUS CHALLENGE", font:.system(size:28,weight:.black,design:.monospaced), color:DS.purple)
                Text("20 Questions • Science-Backed\nProductivity & Focus Mastery")
                    .font(.system(size:14,weight:.medium,design:.monospaced)).foregroundColor(.white.opacity(0.7))
                    .multilineTextAlignment(.center)
            }
            VStack(spacing:12) {
                ruleRow("20 seconds per question")
                ruleRow("+10 XP per correct answer")
                ruleRow("+100 XP bonus for perfect score")
                ruleRow("Mini-game unlocks on completion")
            }.padding(.horizontal,40)
            Spacer()
            PressButton(action:{ startQuiz() }) {
                Text("BEGIN CHALLENGE").font(.system(size:17,weight:.black,design:.monospaced)).foregroundColor(.black)
                    .frame(maxWidth:.infinity).padding(.vertical,18)
                    .background(LinearGradient(colors:[DS.purple, DS.cyan], startPoint:.leading, endPoint:.trailing))
                    .clipShape(RoundedRectangle(cornerRadius:18))
                    .shadow(color:DS.purple.opacity(0.5), radius:12)
            }.padding(.horizontal,28)
            .padding(.bottom,100)
        }.padding(.horizontal,24)
    }

    func ruleRow(_ text: String) -> some View {
        HStack(spacing:10) {
            Circle().fill(DS.purple.opacity(0.8)).frame(width:8,height:8)
            Text(text).font(.system(size:14,design:.monospaced)).foregroundColor(.white.opacity(0.8))
            Spacer()
        }
    }

    func quizActiveView(_ q: QuizQuestion) -> some View {
        VStack(spacing:16) {
            HStack {
                Text("Q \(currentQ+1)/\(shuffledQ.count)")
                    .font(.system(size:14,weight:.bold,design:.monospaced)).foregroundColor(DS.purple.opacity(0.8))
                Spacer()
                HStack(spacing:6) {
                    Image(systemName:"star.fill").foregroundColor(DS.gold).font(.system(size:12))
                    Text("\(score * 10) XP").font(.system(size:14,weight:.bold,design:.monospaced)).foregroundColor(DS.gold)
                }
            }.padding(.horizontal,20).padding(.top,60)

            ZStack {
                Circle().stroke(DS.purple.opacity(0.15), lineWidth:5).frame(width:54,height:54)
                Circle().trim(from:0, to:progressAnim)
                    .stroke(timerColor, style:StrokeStyle(lineWidth:5, lineCap:.round))
                    .frame(width:54,height:54).rotationEffect(.degrees(-90))
                    .animation(.linear(duration:1), value:progressAnim)
                Text("\(timeLeft)").font(.system(size:18,weight:.black,design:.monospaced)).foregroundColor(timerColor)
            }

            XPBar(progress:Double(currentQ)/Double(shuffledQ.count), color:DS.purple).padding(.horizontal,20)

            CyberCard(glowColor:DS.purple) {
                Text(q.question).font(.system(size:16,weight:.semibold,design:.rounded))
                    .foregroundColor(.white).multilineTextAlignment(.center)
                    .padding(20).fixedSize(horizontal:false,vertical:true)
            }.padding(.horizontal,20)
            .offset(x:shakeOffset)

            VStack(spacing:10) {
                ForEach(q.options, id:\.self) { option in
                    PressButton(action:{ guard !showResult else { return }; selectAnswer(option, correct:q.correctAnswer) }) {
                        HStack {
                            Text(option).font(.system(size:15,weight:.semibold,design:.monospaced)).foregroundColor(answerColor(option, correct:q.correctAnswer))
                            Spacer()
                            if showResult {
                                if option == q.correctAnswer { Image(systemName:"checkmark.circle.fill").foregroundColor(DS.green) }
                                else if option == selectedAnswer { Image(systemName:"xmark.circle.fill").foregroundColor(DS.red) }
                            }
                        }.padding(16)
                        .background(RoundedRectangle(cornerRadius:16).fill(answerBg(option, correct:q.correctAnswer)))
                        .overlay(RoundedRectangle(cornerRadius:16).stroke(answerBorder(option, correct:q.correctAnswer), lineWidth:1.5))
                    }
                }
            }.padding(.horizontal,20)

            if showResult {
                CyberCard(glowColor: isCorrect ? DS.green : DS.red) {
                    VStack(spacing:4) {
                        Text(isCorrect ? "✓ CORRECT!" : "✗ INCORRECT").font(.system(size:14,weight:.black,design:.monospaced))
                            .foregroundColor(isCorrect ? DS.green : DS.red)
                        if let q = currentQuestion {
                            Text(q.explanation).font(.system(size:12)).foregroundColor(.white.opacity(0.75))
                                .multilineTextAlignment(.center)
                        }
                    }.padding(14)
                }.padding(.horizontal,20)

                PressButton(action:{ nextQuestion() }) {
                    Text(currentQ < shuffledQ.count-1 ? "NEXT QUESTION →" : "SEE RESULTS")
                        .font(.system(size:15,weight:.black,design:.monospaced)).foregroundColor(.black)
                        .frame(maxWidth:.infinity).padding(.vertical,14)
                        .background(DS.greenGradient).clipShape(RoundedRectangle(cornerRadius:16))
                }.padding(.horizontal,20)
            }
            Spacer()
        }
    }

    var timerColor: Color {
        if timeLeft > 10 { return DS.green }
        if timeLeft > 5 { return DS.gold }
        return DS.red
    }

    func answerColor(_ opt: String, correct: String) -> Color {
        guard showResult else { return .white }
        if opt == correct { return DS.green }
        if opt == selectedAnswer { return DS.red }
        return .white.opacity(0.5)
    }
    func answerBg(_ opt: String, correct: String) -> Color {
        guard showResult else { return selectedAnswer == opt ? DS.purple.opacity(0.2) : DS.cardBg }
        if opt == correct { return DS.green.opacity(0.15) }
        if opt == selectedAnswer { return DS.red.opacity(0.15) }
        return DS.cardBg
    }
    func answerBorder(_ opt: String, correct: String) -> Color {
        guard showResult else { return selectedAnswer == opt ? DS.purple : DS.green.opacity(0.2) }
        if opt == correct { return DS.green.opacity(0.8) }
        if opt == selectedAnswer { return DS.red.opacity(0.8) }
        return DS.green.opacity(0.15)
    }

    var quizResultView: some View {
        ScrollView(showsIndicators:false) {
            VStack(spacing:24) {
                Spacer(minLength:60)
                Text(score == shuffledQ.count ? "🏆 PERFECT!" : score >= shuffledQ.count/2 ? "⚡ GREAT JOB!" : "💡 KEEP LEARNING!")
                    .font(.system(size:32,weight:.black,design:.monospaced)).foregroundColor(DS.gold)
                    .shadow(color:DS.gold.opacity(0.5), radius:12)
                    .multilineTextAlignment(.center)

                CyberCard(glowColor:DS.gold) {
                    VStack(spacing:16) {
                        HStack(spacing:30) {
                            statCol("\(score)/\(shuffledQ.count)", "CORRECT", DS.green)
                            statCol("\(Int(Double(score)/Double(shuffledQ.count)*100))%", "ACCURACY", DS.cyan)
                            statCol("+\(xpEarned)", "XP EARNED", DS.gold)
                        }
                        XPBar(progress:appState.xpProgress(), color:DS.green)
                        Text("Level \(appState.currentLevel) • \(appState.totalXP) XP total").font(.system(size:12,design:.monospaced)).foregroundColor(.white.opacity(0.6))
                    }.padding(20)
                }.padding(.horizontal,20)

                PressButton(action:{ showSpriteKit = true }) {
                    HStack(spacing:12) {
                        Image(systemName:"gamecontroller.fill").font(.title3)
                        Text("PLAY FOCUS GAME").font(.system(size:16,weight:.black,design:.monospaced))
                    }.foregroundColor(.black).frame(maxWidth:.infinity).padding(.vertical,16)
                    .background(LinearGradient(colors:[DS.purple, DS.cyan], startPoint:.leading, endPoint:.trailing))
                    .clipShape(RoundedRectangle(cornerRadius:18)).shadow(color:DS.purple.opacity(0.5), radius:12)
                }.padding(.horizontal,20)

                PressButton(action:{ restartQuiz() }) {
                    Text("TRY AGAIN").font(.system(size:15,weight:.bold,design:.monospaced)).foregroundColor(DS.green)
                        .frame(maxWidth:.infinity).padding(.vertical,14)
                        .background(RoundedRectangle(cornerRadius:16).stroke(DS.green.opacity(0.5), lineWidth:1.5))
                }.padding(.horizontal,20)
                Spacer(minLength:100)
            }
        }
    }

    func statCol(_ value: String, _ label: String, _ color: Color) -> some View {
        VStack(spacing:4) {
            Text(value).font(.system(size:24,weight:.black,design:.monospaced))
                .foregroundStyle(LinearGradient(colors:[color, color.opacity(0.6)], startPoint:.top, endPoint:.bottom))
            Text(label).font(.system(size:10,weight:.bold,design:.monospaced)).foregroundColor(.white.opacity(0.5))
        }
    }

    func startQuiz() {
        shuffledQ = DataSeed.questions.shuffled()
        currentQ = 0; score = 0; xpEarned = 0; quizComplete = false; quizStarted = true
        selectedAnswer = nil; showResult = false
        startTimer()
    }

    func startTimer() {
        timer?.invalidate(); timeLeft = 20; progressAnim = 1.0
        timer = Timer.scheduledTimer(withTimeInterval:1, repeats:true) { _ in
            if timeLeft > 0 { timeLeft -= 1; progressAnim = Double(timeLeft)/20.0 }
            else { timeOut() }
        }
    }

    func timeOut() {
        timer?.invalidate()
        if !showResult {
            selectedAnswer = nil; isCorrect = false; showResult = true
            withAnimation { showFlash = true; flashColor = DS.red }
            DispatchQueue.main.asyncAfter(deadline:.now()+0.4) { withAnimation { showFlash = false } }
            triggerShake()
        }
    }

    func selectAnswer(_ answer: String, correct: String) {
        timer?.invalidate(); selectedAnswer = answer
        isCorrect = answer == correct
        if isCorrect { score += 1; xpEarned += 10; appState.addXP(10) }
        withAnimation(.easeIn(duration:0.15)) { showFlash = true; flashColor = isCorrect ? DS.green : DS.red }
        DispatchQueue.main.asyncAfter(deadline:.now()+0.4) { withAnimation { showFlash = false } }
        if !isCorrect { triggerShake() }
        UIImpactFeedbackGenerator(style: isCorrect ? .heavy : .rigid).impactOccurred()
        withAnimation(.spring()) { showResult = true }
    }

    func triggerShake() {
        withAnimation(.spring(response:0.1, dampingFraction:0.2)) { shakeOffset = 10 }
        DispatchQueue.main.asyncAfter(deadline:.now()+0.1) { withAnimation(.spring(response:0.1,dampingFraction:0.2)) { shakeOffset = -10 } }
        DispatchQueue.main.asyncAfter(deadline:.now()+0.2) { withAnimation(.spring()) { shakeOffset = 0 } }
    }

    func nextQuestion() {
        if currentQ < shuffledQ.count - 1 {
            withAnimation(.spring()) { currentQ += 1; showResult = false; selectedAnswer = nil }
            startTimer()
        } else {
            timer?.invalidate()
            if score == shuffledQ.count { xpEarned += 100; appState.addXP(100) }
            let record = SessionRecord(date:Date(), score:score, xpEarned:xpEarned, duration:shuffledQ.count*20, sessionType:"Quiz")
            appState.addSession(record)
            withAnimation(.spring()) { quizComplete = true; quizStarted = false }
        }
    }

    func restartQuiz() { timer?.invalidate(); quizStarted = false; quizComplete = false; shuffledQ = [] }
}

// MARK: - SpriteKit Game
class FocusGameScene: SKScene {
    var score = 0
    var lives = 3
    var onScoreChange: ((Int) -> Void)?
    var onLivesChange: ((Int) -> Void)?
    var onGameOver: ((Int) -> Void)?
    private var spawnTimer: TimeInterval = 0
    private var spawnInterval: TimeInterval = 1.2
    private var bgNode: SKSpriteNode?

    override func didMove(to view: SKView) {
        backgroundColor = UIColor(red:0.04,green:0.07,blue:0.05,alpha:1)
        addGrid()
        addParticleEmitter()
        let border = SKPhysicsBody(edgeLoopFrom:frame)
        physicsBody = border
        physicsWorld.gravity = CGVector(dx:0, dy:-2)
    }

    func addGrid() {
        let lines = SKShapeNode()
        let path = CGMutablePath()
        var x: CGFloat = 0
        while x < frame.width { path.move(to:CGPoint(x:x,y:0)); path.addLine(to:CGPoint(x:x,y:frame.height)); x += 40 }
        var y: CGFloat = 0
        while y < frame.height { path.move(to:CGPoint(x:0,y:y)); path.addLine(to:CGPoint(x:frame.width,y:y)); y += 40 }
        lines.path = path; lines.strokeColor = UIColor(red:0.1,green:0.9,blue:0.45,alpha:0.07); lines.lineWidth = 0.5; lines.zPosition = -1
        addChild(lines)
    }

    func addParticleEmitter() {
        let emitter = SKEmitterNode()
        emitter.particleTexture = SKTexture(imageNamed:"spark")
        emitter.particleBirthRate = 8
        emitter.particleLifetime = 3; emitter.particleLifetimeRange = 2
        emitter.particleSpeed = 60; emitter.particleSpeedRange = 40
        emitter.particleAlpha = 0.7; emitter.particleAlphaSpeed = -0.3
        emitter.particleScale = 0.05; emitter.particleScaleRange = 0.05
        emitter.emissionAngle = .pi/2; emitter.emissionAngleRange = .pi*2
        emitter.particleColor = UIColor(red:0.1,green:0.9,blue:0.45,alpha:1)
        emitter.position = CGPoint(x:frame.midX, y:0)
        emitter.zPosition = 0
        addChild(emitter)
    }

    func spawnOrb() {
        let orb = SKShapeNode(circleOfRadius:22)
        let colors: [UIColor] = [UIColor(red:0.1,green:0.9,blue:0.45,alpha:1), UIColor(red:0,green:0.85,blue:0.9,alpha:1), UIColor(red:0.55,green:0.1,blue:0.95,alpha:1), UIColor(red:1,green:0.8,blue:0.1,alpha:1)]
        let c = colors.randomElement()!
        orb.fillColor = c.withAlphaComponent(0.3); orb.strokeColor = c; orb.lineWidth = 2
        orb.glowWidth = 6
        let x = CGFloat.random(in:30...(frame.width-30))
        orb.position = CGPoint(x:x, y:frame.height+30)
        let label = SKLabelNode(text:"●")
        label.fontSize = 14; label.fontColor = c; label.verticalAlignmentMode = .center; label.horizontalAlignmentMode = .center
        orb.addChild(label)
        let physics = SKPhysicsBody(circleOfRadius:22)
        physics.isDynamic = true; physics.restitution = 0.3; physics.friction = 0.2
        orb.physicsBody = physics
        orb.name = "orb"
        addChild(orb)
    }

    override func update(_ currentTime: TimeInterval) {
        spawnTimer += 1.0/60.0
        if spawnTimer >= spawnInterval {
            spawnTimer = 0; spawnOrb()
            spawnInterval = max(0.5, spawnInterval - 0.01)
        }
        for node in children where node.name == "orb" {
            if node.position.y < -50 {
                node.removeFromParent(); lives -= 1
                onLivesChange?(lives)
                if lives <= 0 { onGameOver?(score) }
            }
        }
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let touch = touches.first else { return }
        let loc = touch.location(in:self)
        let hit = atPoint(loc)
        let target = hit.name == "orb" ? hit as? SKShapeNode : hit.parent as? SKShapeNode
        if let orb = target, orb.name == "orb" {
            score += 1
            onScoreChange?(score)
            let burst = SKEmitterNode()
            burst.particleBirthRate = 100; burst.particleLifetime = 0.6; burst.numParticlesToEmit = 20
            burst.particleSpeed = 120; burst.particleAlpha = 0.9; burst.particleAlphaSpeed = -2.5
            burst.particleScale = 0.08; burst.emissionAngle = 0; burst.emissionAngleRange = .pi*2
            burst.particleColor = orb.strokeColor
            burst.position = orb.position; burst.zPosition = 2
            addChild(burst)
            orb.removeFromParent()
            DispatchQueue.main.asyncAfter(deadline:.now()+1) { burst.removeFromParent() }
        }
    }
}

struct SpriteKitGameView: View {
    @EnvironmentObject var appState: AppState
    @Environment(\.dismiss) var dismiss
    @State private var score = 0
    @State private var lives = 3
    @State private var gameOver = false
    @State private var scene: FocusGameScene?

    var body: some View {
        ZStack {
            if !gameOver {
                GeometryReader { geo in
                    SpriteView(scene:makeScene(geo.size)).ignoresSafeArea()
                }
                VStack {
                    HStack {
                        PressButton(action:{ dismiss() }) {
                            Image(systemName:"xmark").font(.title3).foregroundColor(.white.opacity(0.7)).padding(12)
                                .background(Circle().fill(Color.black.opacity(0.5)))
                        }
                        Spacer()
                        CyberCard(glowColor:DS.gold) {
                            HStack(spacing:6) {
                                Image(systemName:"star.fill").foregroundColor(DS.gold).font(.system(size:14))
                                Text("\(score)").font(.system(size:20,weight:.black,design:.monospaced)).foregroundColor(.white)
                            }.padding(.horizontal,16).padding(.vertical,8)
                        }
                        Spacer()
                        HStack(spacing:4) {
                            ForEach(0..<3) { i in
                                Text(i < lives ? "❤️" : "🖤").font(.system(size:18))
                            }
                        }
                    }.padding(.horizontal,20).padding(.top,50)
                    Spacer()
                    Text("TAP THE FOCUS ORBS!")
                        .font(.system(size:14,weight:.bold,design:.monospaced)).foregroundColor(DS.green.opacity(0.8))
                        .padding(.bottom,20)
                }
            } else {
                gameOverView
            }
        }
    }

    func makeScene(_ size: CGSize) -> FocusGameScene {
        if let existing = scene { return existing }
        let s = FocusGameScene(size:size)
        s.scaleMode = .resizeFill
        s.onScoreChange = { self.score = $0 }
        s.onLivesChange = { self.lives = $0 }
        s.onGameOver = { finalScore in
            self.score = finalScore
            let xp = min(finalScore * 5, 100)
            appState.addXP(xp)
            withAnimation(.spring()) { self.gameOver = true }
        }
        scene = s; return s
    }

    var gameOverView: some View {
        ZStack {
            DS.mainGradient.ignoresSafeArea()
            GridBackground()
            ParticleView()
            VStack(spacing:28) {
                GlowingText(text:"GAME OVER", font:.system(size:36,weight:.black,design:.monospaced), color:DS.red)
                CyberCard(glowColor:DS.gold) {
                    VStack(spacing:12) {
                        Text("FINAL SCORE").font(.system(size:14,weight:.bold,design:.monospaced)).foregroundColor(.white.opacity(0.6))
                        Text("\(score)").font(.system(size:54,weight:.black,design:.monospaced))
                            .foregroundStyle(LinearGradient(colors:[DS.gold, DS.green], startPoint:.top, endPoint:.bottom))
                        Text("+\(min(score*5,100)) XP earned").font(.system(size:14,design:.monospaced)).foregroundColor(DS.green)
                    }.padding(24)
                }
                PressButton(action:{ dismiss() }) {
                    Text("BACK TO QUIZ").font(.system(size:16,weight:.black,design:.monospaced)).foregroundColor(.black)
                        .frame(maxWidth:.infinity).padding(.vertical,16)
                        .background(DS.greenGradient).clipShape(RoundedRectangle(cornerRadius:16))
                }.padding(.horizontal,40)
            }
        }
    }
}

// MARK: - Analytics View
struct AnalyticsView: View {
    @EnvironmentObject var appState: AppState
    @State private var animateCharts = false

    var weeklyData: [Double] {
        let cal = Calendar.current
        return (0..<7).map { offset -> Double in
            guard let day = cal.date(byAdding:.day, value:-(6-offset), to:Date()) else { return 0 }
            let start = cal.startOfDay(for:day)
            guard let end = cal.date(byAdding:.day, value:1, to:start) else { return 0 }
            return Double(appState.sessionHistory.filter { $0.date >= start && $0.date < end }.count)
        }
    }

    var monthlyXP: [Double] {
        let cal = Calendar.current
        return (0..<4).map { offset -> Double in
            guard let week = cal.date(byAdding:.weekOfYear, value:-(3-offset), to:Date()) else { return 0 }
            let start = cal.startOfDay(for:week)
            guard let end = cal.date(byAdding:.weekOfYear, value:1, to:start) else { return 0 }
            return Double(appState.sessionHistory.filter { $0.date >= start && $0.date < end }.reduce(0) { $0 + $1.xpEarned })
        }
    }

    var bestScore: Int { appState.sessionHistory.map { $0.score }.max() ?? 0 }
    var totalSessions: Int { appState.sessionHistory.count }
    var avgScore: Double {
        let quizSessions = appState.sessionHistory.filter { $0.sessionType == "Quiz" }
        guard !quizSessions.isEmpty else { return 0 }
        return Double(quizSessions.map { $0.score }.reduce(0,+)) / Double(quizSessions.count)
    }

    var body: some View {
        ZStack {
            DS.mainGradient.ignoresSafeArea()
            GridBackground()
            ScanlineOverlay()
            ScrollView(showsIndicators:false) {
                VStack(spacing:20) {
                    header
                    summaryRow
                    weeklyChart
                    monthlyChart
                    streakCalendar
                    historyLog
                }
                .padding(.horizontal,20)
                .padding(.top,60)
                .padding(.bottom,120)
            }
        }
        .onAppear { withAnimation(.spring().delay(0.2)) { animateCharts = true } }
    }

    var header: some View {
        HStack {
            GlowingText(text:"ANALYTICS", font:.system(size:24,weight:.black,design:.monospaced), color:DS.cyan)
            Spacer()
        }
    }

    var summaryRow: some View {
        HStack(spacing:12) {
            analyticsCard("SESSIONS", "\(totalSessions)", "clock.fill", DS.cyan)
            analyticsCard("AVG SCORE", "\(Int(avgScore*100/20))%", "target", DS.green)
            analyticsCard("BEST", "\(bestScore)/20", "trophy.fill", DS.gold)
        }
    }

    func analyticsCard(_ label: String, _ value: String, _ icon: String, _ color: Color) -> some View {
        CyberCard(glowColor:color) {
            VStack(spacing:6) {
                Image(systemName:icon).font(.system(size:18))
                    .foregroundStyle(LinearGradient(colors:[color, color.opacity(0.6)], startPoint:.top, endPoint:.bottom))
                Text(value).font(.system(size:20,weight:.black,design:.monospaced)).foregroundColor(.white)
                Text(label).font(.system(size:9,weight:.bold,design:.monospaced)).foregroundColor(.white.opacity(0.5))
            }.padding(.vertical,14).frame(maxWidth:.infinity)
        }
    }

    var weeklyChart: some View {
        CyberCard(glowColor:DS.green) {
            VStack(alignment:.leading, spacing:14) {
                Text("WEEKLY SESSIONS").font(.system(size:13,weight:.bold,design:.monospaced)).foregroundColor(DS.green.opacity(0.8))
                let days = ["Mon","Tue","Wed","Thu","Fri","Sat","Sun"]
                let maxVal = max(weeklyData.max() ?? 1, 1)
                HStack(alignment:.bottom, spacing:8) {
                    ForEach(0..<7) { i in
                        VStack(spacing:6) {
                            RoundedRectangle(cornerRadius:6)
                                .fill(LinearGradient(colors:[DS.green, DS.cyan], startPoint:.top, endPoint:.bottom))
                                .frame(width:32, height:animateCharts ? CGFloat(weeklyData[i]/maxVal)*80 : 0)
                                .shadow(color:DS.green.opacity(0.4), radius:4)
                                .animation(.spring().delay(Double(i)*0.08), value:animateCharts)
                            Text(days[i]).font(.system(size:9,design:.monospaced)).foregroundColor(.white.opacity(0.5))
                        }
                    }
                }.frame(maxWidth:.infinity)
            }.padding(16)
        }
    }

    var monthlyChart: some View {
        CyberCard(glowColor:DS.cyan) {
            VStack(alignment:.leading, spacing:14) {
                Text("WEEKLY XP EARNED").font(.system(size:13,weight:.bold,design:.monospaced)).foregroundColor(DS.cyan.opacity(0.8))
                let maxVal = max(monthlyXP.max() ?? 1, 1)
                let weeks = ["Wk1","Wk2","Wk3","Wk4"]
                GeometryReader { geo in
                    let pts = monthlyXP.enumerated().map { i, val -> CGPoint in
                        CGPoint(x:CGFloat(i) / CGFloat(monthlyXP.count-1) * geo.size.width, y:geo.size.height - CGFloat(val/maxVal) * geo.size.height)
                    }
                    ZStack(alignment:.topLeading) {
                        if pts.count > 1 {
                            Path { path in path.move(to:pts[0]); for pt in pts.dropFirst() { path.addLine(to:pt) } }
                                .stroke(LinearGradient(colors:[DS.cyan, DS.green], startPoint:.leading, endPoint:.trailing), style:StrokeStyle(lineWidth:3, lineCap:.round, lineJoin:.round))
                                .shadow(color:DS.cyan.opacity(0.6), radius:4)
                        }
                        ForEach(0..<pts.count, id:\.self) { i in
                            Circle().fill(DS.cyan).frame(width:10,height:10)
                                .shadow(color:DS.cyan.opacity(0.8), radius:4)
                                .position(pts[i])
                        }
                    }
                }.frame(height:80)
                HStack {
                    ForEach(weeks, id:\.self) { w in
                        Text(w).font(.system(size:10,design:.monospaced)).foregroundColor(.white.opacity(0.5)).frame(maxWidth:.infinity)
                    }
                }
            }.padding(16)
        }
    }

    var streakCalendar: some View {
        CyberCard(glowColor:DS.gold) {
            VStack(alignment:.leading, spacing:12) {
                Text("ACTIVITY CALENDAR").font(.system(size:13,weight:.bold,design:.monospaced)).foregroundColor(DS.gold.opacity(0.8))
                let cal = Calendar.current
                let days = (0..<28).map { offset -> (Date, Bool) in
                    let d = cal.date(byAdding:.day, value:-(27-offset), to:Date())!
                    let start = cal.startOfDay(for:d)
                    let end = cal.date(byAdding:.day, value:1, to:start)!
                    let active = appState.sessionHistory.contains { $0.date >= start && $0.date < end }
                    return (d, active)
                }
                LazyVGrid(columns:Array(repeating:GridItem(.flexible()),count:7), spacing:6) {
                    ForEach(0..<28) { i in
                        let (date, active) = days[i]
                        let isToday = cal.isDateInToday(date)
                        RoundedRectangle(cornerRadius:6)
                            .fill(active ? DS.green.opacity(0.8) : DS.cardBg)
                            .frame(height:32)
                            .overlay(RoundedRectangle(cornerRadius:6).stroke(isToday ? DS.gold : Color.clear, lineWidth:2))
                            .overlay(Text("\(cal.component(.day,from:date))").font(.system(size:10,design:.monospaced)).foregroundColor(active ? .black : .white.opacity(0.4)))
                    }
                }
            }.padding(16)
        }
    }

    var historyLog: some View {
        VStack(alignment:.leading, spacing:12) {
            Text("SESSION HISTORY").font(.system(size:13,weight:.bold,design:.monospaced)).foregroundColor(.white.opacity(0.7))
            if appState.sessionHistory.isEmpty {
                CyberCard(glowColor:DS.green.opacity(0.3)) {
                    Text("Complete sessions to see your history here.")
                        .font(.system(size:13)).foregroundColor(.white.opacity(0.5))
                        .frame(maxWidth:.infinity).multilineTextAlignment(.center).padding(20)
                }
            } else {
                ForEach(appState.sessionHistory.reversed().prefix(10)) { session in
                    CyberCard(glowColor:DS.green.opacity(0.4)) {
                        HStack(spacing:12) {
                            Image(systemName:session.sessionType == "Quiz" ? "brain.head.profile" : "timer")
                                .font(.system(size:18)).foregroundColor(DS.green)
                            VStack(alignment:.leading, spacing:3) {
                                Text(session.sessionType).font(.system(size:13,weight:.bold,design:.monospaced)).foregroundColor(.white)
                                Text(session.date, style:.date).font(.system(size:11,design:.monospaced)).foregroundColor(.white.opacity(0.5))
                            }
                            Spacer()
                            VStack(alignment:.trailing, spacing:2) {
                                if session.sessionType == "Quiz" {
                                    Text("\(session.score)/20").font(.system(size:14,weight:.black,design:.monospaced)).foregroundColor(DS.cyan)
                                }
                                Text("+\(session.xpEarned) XP").font(.system(size:12,weight:.bold,design:.monospaced)).foregroundColor(DS.gold)
                            }
                            if session.score == 20 && session.sessionType == "Quiz" {
                                Image(systemName:"trophy.fill").foregroundColor(DS.gold).shadow(color:DS.gold.opacity(0.7), radius:4)
                            }
                        }.padding(14)
                    }
                }
            }
        }
    }
}

// MARK: - Profile View
struct ProfileView: View {
    @EnvironmentObject var appState: AppState
    @State private var ringRotation: Double = 0
    @State private var shimmerOffset: CGFloat = -200
    @State private var cardAppear = false
    @State private var showShare = false

    let achievements = DataSeed.achievements

    var body: some View {
        ZStack {
            DS.mainGradient.ignoresSafeArea()
            GridBackground()
            ScanlineOverlay()
            ParticleView()

            ScrollView(showsIndicators:false) {
                VStack(spacing:24) {
                    avatarSection
                    levelSection
                    statsRow
                    achievementsSection
                    trophiesSection
                    shareSection
                }
                .padding(.horizontal,20)
                .padding(.top,60)
                .padding(.bottom,120)
            }
        }
        .onAppear {
            withAnimation(.linear(duration:6).repeatForever(autoreverses:false)) { ringRotation = 360 }
            withAnimation(.linear(duration:2.5).repeatForever(autoreverses:false).delay(0.3)) { shimmerOffset = 400 }
            withAnimation(.spring().delay(0.1)) { cardAppear = true }
        }
        .sheet(isPresented:$showShare) {
            ShareSheet(items:["I'm Level \(appState.currentLevel) with \(appState.totalXP) XP on CoCoFocus Core! 🧠⚡\nStreak: \(appState.currentStreak) days | Achievements: \(appState.achievementsUnlocked.count)/\(achievements.count)\n#CoCoFocus Core #DeepWork #Productivity"])
        }
    }

    var avatarSection: some View {
        VStack(spacing:14) {
            ZStack {
                Circle()
                    .stroke(AngularGradient(colors:[DS.green, DS.cyan, DS.purple, DS.gold, DS.green], center:.center), lineWidth:3)
                    .frame(width:114, height:114)
                    .rotationEffect(.degrees(ringRotation))
                Circle()
                    .stroke(DS.green.opacity(0.2), lineWidth:10)
                    .frame(width:120, height:120)
                if let data = appState.userPhotoData, let img = UIImage(data:data) {
                    Image(uiImage:img).resizable().scaledToFill()
                        .frame(width:108, height:108).clipShape(Circle())
                } else {
                    ZStack {
                        Circle().fill(DS.cardBg).frame(width:108,height:108)
                        Image(systemName:"person.fill").font(.system(size:44))
                            .foregroundStyle(LinearGradient(colors:[DS.green,DS.cyan], startPoint:.topLeading, endPoint:.bottomTrailing))
                    }
                }
                VStack {
                    Spacer()
                    HStack {
                        Spacer()
                        ZStack {
                            Circle().fill(DS.gold).frame(width:28,height:28)
                            Text("\(appState.currentLevel)").font(.system(size:12,weight:.black,design:.monospaced)).foregroundColor(.black)
                        }
                    }
                }.frame(width:110,height:110)
            }
            GlowingText(
                text: appState.userName.isEmpty ? "COMMANDER" : appState.userName.uppercased(),
                font: .system(size:24, weight:.black, design:.monospaced),
                color: .white
            )
            Text(levelTitle(appState.currentLevel))
                .font(.system(size:13, weight:.medium, design:.monospaced))
                .foregroundColor(DS.green.opacity(0.8))
        }
        .opacity(cardAppear ? 1 : 0)
        .offset(y: cardAppear ? 0 : 20)
    }

    func levelTitle(_ lv: Int) -> String {
        switch lv {
        case 1: return "NOVICE FOCUSER"
        case 2: return "ATTENTION APPRENTICE"
        case 3: return "FOCUS ADEPT"
        case 4: return "DEEP WORK SPECIALIST"
        case 5: return "FLOW STATE ENGINEER"
        case 6: return "PRODUCTIVITY MASTER"
        case 7: return "COGNITIVE ARCHITECT"
        case 8: return "MIND COMMANDER"
        case 9: return "FOCUS SOVEREIGN"
        default: return "COCOFOCUS CORE LEGEND"
        }
    }

    var levelSection: some View {
        CyberCard(glowColor:DS.green) {
            VStack(spacing:10) {
                HStack {
                    Text("LEVEL \(appState.currentLevel)")
                        .font(.system(size:16, weight:.black, design:.monospaced))
                        .foregroundStyle(LinearGradient(colors:[DS.green, DS.cyan], startPoint:.leading, endPoint:.trailing))
                    Spacer()
                    Text("\(appState.totalXP) / \(appState.xpForNextLevel()) XP")
                        .font(.system(size:13, weight:.bold, design:.monospaced))
                        .foregroundColor(DS.gold)
                }
                XPBar(progress:appState.xpProgress(), color:DS.green)
                HStack {
                    Text("\(appState.totalXP - appState.xpForCurrentLevel()) XP this level")
                        .font(.system(size:11, design:.monospaced)).foregroundColor(.white.opacity(0.5))
                    Spacer()
                    Text("\(appState.xpForNextLevel() - appState.totalXP) XP to next")
                        .font(.system(size:11, design:.monospaced)).foregroundColor(DS.green.opacity(0.7))
                }
            }.padding(18)
        }
        .opacity(cardAppear ? 1 : 0)
        .animation(.spring().delay(0.15), value:cardAppear)
    }

    var statsRow: some View {
        HStack(spacing:12) {
            profileStatCard("\(appState.currentStreak)", "DAY\nSTREAK", "flame.fill", DS.red)
            profileStatCard("\(appState.lessonsCompleted.count)", "LESSONS\nDONE", "book.fill", DS.cyan)
            profileStatCard("\(appState.achievementsUnlocked.count)", "ACHIEVE-\nMENTS", "trophy.fill", DS.gold)
        }
        .opacity(cardAppear ? 1 : 0)
        .animation(.spring().delay(0.2), value:cardAppear)
    }

    func profileStatCard(_ value:String, _ label:String, _ icon:String, _ color:Color) -> some View {
        CyberCard(glowColor:color) {
            VStack(spacing:6) {
                Image(systemName:icon).font(.system(size:18))
                    .foregroundStyle(LinearGradient(colors:[color, color.opacity(0.6)], startPoint:.top, endPoint:.bottom))
                    .shadow(color:color.opacity(0.5), radius:4)
                Text(value).font(.system(size:22, weight:.black, design:.monospaced)).foregroundColor(.white)
                Text(label).font(.system(size:9, weight:.bold, design:.monospaced))
                    .foregroundColor(.white.opacity(0.5)).multilineTextAlignment(.center)
            }.padding(.vertical,14).frame(maxWidth:.infinity)
        }
    }

    var achievementsSection: some View {
        VStack(alignment:.leading, spacing:12) {
            HStack {
                Text("ACHIEVEMENTS").font(.system(size:14,weight:.black,design:.monospaced)).foregroundColor(.white)
                Spacer()
                Text("\(appState.achievementsUnlocked.count)/\(achievements.count)")
                    .font(.system(size:12,design:.monospaced)).foregroundColor(DS.green.opacity(0.7))
            }
            LazyVGrid(columns:[GridItem(.flexible()), GridItem(.flexible())], spacing:12) {
                ForEach(achievements) { ach in
                    achievementCard(ach)
                }
            }
        }
        .opacity(cardAppear ? 1 : 0)
        .animation(.spring().delay(0.25), value:cardAppear)
    }

    func achievementCard(_ ach: Achievement) -> some View {
        let unlocked = appState.achievementsUnlocked.contains(ach.id)
        return CyberCard(glowColor: unlocked ? ach.rarityColor : Color.white.opacity(0.1)) {
            VStack(spacing:8) {
                ZStack {
                    if unlocked && ach.rarity == .legendary {
                        RoundedRectangle(cornerRadius:12)
                            .fill(LinearGradient(colors:[DS.gold.opacity(0.3), DS.gold.opacity(0.05)], startPoint:.topLeading, endPoint:.bottomTrailing))
                            .frame(width:52,height:52)
                        RoundedRectangle(cornerRadius:12)
                            .fill(LinearGradient(colors:[Color.white.opacity(0.35), Color.clear], startPoint:.init(x:shimmerOffset/400,y:0), endPoint:.init(x:(shimmerOffset+200)/400,y:1)))
                            .frame(width:52,height:52)
                            .clipped()
                    }
                    Image(systemName:ach.icon).font(.system(size:24))
                        .foregroundStyle(unlocked ?
                            AnyShapeStyle(LinearGradient(colors:[ach.rarityColor, ach.rarityColor.opacity(0.6)], startPoint:.topLeading, endPoint:.bottomTrailing)) :
                            AnyShapeStyle(Color.white.opacity(0.15))
                        )
                        .shadow(color: unlocked ? ach.rarityColor.opacity(0.6) : Color.clear, radius:6)
                }
                Text(ach.name).font(.system(size:12,weight:.bold,design:.monospaced))
                    .foregroundColor(unlocked ? .white : .white.opacity(0.3))
                    .multilineTextAlignment(.center).lineLimit(2)
                Text(ach.rarityLabel).font(.system(size:9,weight:.bold,design:.monospaced))
                    .foregroundColor(unlocked ? ach.rarityColor : Color.white.opacity(0.2))
                if !unlocked {
                    Text(ach.description).font(.system(size:9)).foregroundColor(.white.opacity(0.3))
                        .multilineTextAlignment(.center).lineLimit(2)
                }
            }.padding(12).frame(maxWidth:.infinity)
        }
    }

    var trophiesSection: some View {
        VStack(alignment:.leading, spacing:12) {
            Text("TROPHIES").font(.system(size:14,weight:.black,design:.monospaced)).foregroundColor(.white)
            HStack(spacing:14) {
                trophyCard("🥇", "Quiz Master", "Score 20/20 on any quiz", appState.sessionHistory.contains { $0.score == 20 && $0.sessionType == "Quiz" }, DS.gold)
                trophyCard("🏃", "Sprint Legend", "Complete 10+ sessions", appState.sessionHistory.count >= 10, DS.cyan)
                trophyCard("🧠", "Deep Thinker", "Finish all 12 lessons", appState.lessonsCompleted.count >= 12, DS.purple)
            }
        }
        .opacity(cardAppear ? 1 : 0)
        .animation(.spring().delay(0.3), value:cardAppear)
    }

    func trophyCard(_ emoji:String, _ title:String, _ desc:String, _ earned:Bool, _ color:Color) -> some View {
        CyberCard(glowColor: earned ? color : Color.white.opacity(0.1)) {
            VStack(spacing:6) {
                Text(emoji).font(.system(size:32))
                    .grayscale(earned ? 0 : 1)
                    .shadow(color: earned ? color.opacity(0.7) : Color.clear, radius:8)
                Text(title).font(.system(size:11,weight:.bold,design:.monospaced))
                    .foregroundColor(earned ? .white : .white.opacity(0.3)).multilineTextAlignment(.center)
                Text(desc).font(.system(size:9)).foregroundColor(.white.opacity(earned ? 0.6 : 0.25))
                    .multilineTextAlignment(.center).lineLimit(2)
            }.padding(12).frame(maxWidth:.infinity)
        }
    }

    var shareSection: some View {
        PressButton(action:{ showShare = true }) {
            HStack(spacing:10) {
                Image(systemName:"square.and.arrow.up").font(.system(size:16,weight:.bold))
                Text("SHARE MY PROGRESS").font(.system(size:15,weight:.black,design:.monospaced))
            }
            .foregroundColor(.black).frame(maxWidth:.infinity).padding(.vertical,16)
            .background(LinearGradient(colors:[DS.green, DS.cyan], startPoint:.leading, endPoint:.trailing))
            .clipShape(RoundedRectangle(cornerRadius:18))
            .shadow(color:DS.green.opacity(0.5), radius:12)
        }
        .opacity(cardAppear ? 1 : 0)
        .animation(.spring().delay(0.35), value:cardAppear)
    }
}

// MARK: - Settings View
struct SettingsView: View {
    @EnvironmentObject var appState: AppState
    @Environment(\.dismiss) var dismiss
    @State private var name: String = ""
    @State private var selectedImage: UIImage? = nil
    @State private var showImagePicker = false
    @State private var showResetConfirm = false
    @State private var savedPulse = false

    var body: some View {
        ZStack {
            DS.mainGradient.ignoresSafeArea()
            GridBackground()
            ScanlineOverlay()

            ScrollView(showsIndicators:false) {
                VStack(spacing:20) {
                    HStack {
                        PressButton(action:{ dismiss() }) {
                            Image(systemName:"xmark").font(.title3).foregroundColor(.white.opacity(0.7)).padding(14)
                                .background(Circle().fill(DS.cardBg))
                        }
                        Spacer()
                        GlowingText(text:"SETTINGS", font:.system(size:18,weight:.black,design:.monospaced), color:DS.green)
                        Spacer()
                        Circle().fill(Color.clear).frame(width:44,height:44)
                    }.padding(.horizontal,20).padding(.top,50)

                    CyberCard(glowColor:DS.green) {
                        VStack(spacing:18) {
                            Text("PROFILE").font(.system(size:12,weight:.bold,design:.monospaced)).foregroundColor(DS.green.opacity(0.7)).frame(maxWidth:.infinity, alignment:.leading)

                            PressButton(action:{ showImagePicker = true }) {
                                ZStack {
                                    Circle().fill(DS.cardBg).frame(width:90,height:90)
                                    Circle().stroke(DS.green.opacity(0.6), lineWidth:2).frame(width:90,height:90)
                                    if let img = selectedImage {
                                        Image(uiImage:img).resizable().scaledToFill().frame(width:86,height:86).clipShape(Circle())
                                    } else if let data = appState.userPhotoData, let img = UIImage(data:data) {
                                        Image(uiImage:img).resizable().scaledToFill().frame(width:86,height:86).clipShape(Circle())
                                    } else {
                                        VStack(spacing:4) {
                                            Image(systemName:"camera.fill").font(.title3).foregroundColor(DS.green.opacity(0.7))
                                            Text("PHOTO").font(.system(size:9,weight:.bold,design:.monospaced)).foregroundColor(DS.green.opacity(0.5))
                                        }
                                    }
                                }
                            }

                            VStack(alignment:.leading, spacing:8) {
                                Text("DISPLAY NAME").font(.system(size:11,weight:.bold,design:.monospaced)).foregroundColor(DS.green.opacity(0.6))
                                TextField("Your name...", text:$name)
                                    .font(.system(size:16,weight:.medium,design:.monospaced)).foregroundColor(.white).tint(DS.green)
                                    .padding(12)
                                    .background(RoundedRectangle(cornerRadius:10).fill(Color.white.opacity(0.06)))
                                    .overlay(RoundedRectangle(cornerRadius:10).stroke(DS.green.opacity(0.3), lineWidth:1))
                            }

                            PressButton(action:{ saveProfile() }) {
                                HStack {
                                    Image(systemName: savedPulse ? "checkmark.circle.fill" : "square.and.arrow.down.fill")
                                    Text(savedPulse ? "SAVED!" : "SAVE CHANGES")
                                        .font(.system(size:15,weight:.black,design:.monospaced))
                                }
                                .foregroundColor(.black).frame(maxWidth:.infinity).padding(.vertical,14)
                                .background(savedPulse ? AnyView(DS.cyan) : AnyView(DS.greenGradient.asAnyView()))
                                .clipShape(RoundedRectangle(cornerRadius:14))
                                .scaleEffect(savedPulse ? 1.03 : 1.0)
                                .animation(.spring(response:0.3, dampingFraction:0.5), value:savedPulse)
                            }
                        }.padding(18)
                    }.padding(.horizontal,20)

                    CyberCard(glowColor:DS.cyan) {
                        VStack(spacing:14) {
                            Text("APP INFO").font(.system(size:12,weight:.bold,design:.monospaced)).foregroundColor(DS.cyan.opacity(0.7)).frame(maxWidth:.infinity, alignment:.leading)
                            infoRow("Version", "1.0.0", "info.circle.fill", DS.cyan)
                            infoRow("Build", "2026.1", "hammer.fill", DS.cyan)
                            infoRow("Data Storage", "On-Device Only", "lock.shield.fill", DS.green)
                            infoRow("Frameworks", "SwiftUI + SpriteKit", "cpu.fill", DS.purple)
                        }.padding(18)
                    }.padding(.horizontal,20)

                    CyberCard(glowColor:DS.red) {
                        VStack(spacing:14) {
                            Text("DANGER ZONE").font(.system(size:12,weight:.bold,design:.monospaced)).foregroundColor(DS.red.opacity(0.8)).frame(maxWidth:.infinity, alignment:.leading)
                            Text("Resetting will permanently erase all XP, levels, streak, lessons, and achievements. This cannot be undone.")
                                .font(.system(size:12)).foregroundColor(.white.opacity(0.6))
                            PressButton(action:{ showResetConfirm = true }) {
                                HStack {
                                    Image(systemName:"exclamationmark.triangle.fill")
                                    Text("RESET ALL PROGRESS").font(.system(size:14,weight:.black,design:.monospaced))
                                }
                                .foregroundColor(DS.red).frame(maxWidth:.infinity).padding(.vertical,14)
                                .background(RoundedRectangle(cornerRadius:14).stroke(DS.red.opacity(0.6), lineWidth:1.5))
                                .background(RoundedRectangle(cornerRadius:14).fill(DS.red.opacity(0.08)))
                            }
                        }.padding(18)
                    }.padding(.horizontal,20)

                    Spacer(minLength:80)
                }
            }
        }
        .onAppear { name = appState.userName }
        .sheet(isPresented:$showImagePicker) { ImagePicker(image:$selectedImage) }
        .alert("Reset All Progress?", isPresented:$showResetConfirm) {
            Button("Cancel", role:.cancel) {}
            Button("Reset", role:.destructive) {
                appState.resetProgress()
                UINotificationFeedbackGenerator().notificationOccurred(.warning)
            }
        } message: {
            Text("This will permanently delete all your XP, levels, streak, and achievements.")
        }
    }

    func infoRow(_ label:String, _ value:String, _ icon:String, _ color:Color) -> some View {
        HStack(spacing:12) {
            Image(systemName:icon).font(.system(size:14)).foregroundColor(color).frame(width:24)
            Text(label).font(.system(size:13,design:.monospaced)).foregroundColor(.white.opacity(0.7))
            Spacer()
            Text(value).font(.system(size:13,weight:.bold,design:.monospaced)).foregroundColor(.white)
        }
    }

    func saveProfile() {
        if !name.isEmpty { appState.userName = name }
        if let img = selectedImage { appState.userPhotoData = img.jpegData(compressionQuality:0.8) }
        appState.save()
        withAnimation { savedPulse = true }
        DispatchQueue.main.asyncAfter(deadline:.now()+2) { withAnimation { savedPulse = false } }
        UINotificationFeedbackGenerator().notificationOccurred(.success)
    }
}

// MARK: - Level Up Overlay
struct LevelUpOverlay: View {
    let level: Int
    let onDismiss: () -> Void
    @State private var scale: CGFloat = 0.4
    @State private var opacity: Double = 0
    @State private var particleBurst = false

    var body: some View {
        ZStack {
            Color.black.opacity(0.75).ignoresSafeArea()
                .onTapGesture { dismiss() }
            ParticleView()

            VStack(spacing:24) {
                ZStack {
                    ForEach(0..<4) { i in
                        Circle()
                            .stroke(DS.gold.opacity(0.2 - Double(i)*0.04), lineWidth:2)
                            .frame(width:CGFloat(120+i*40), height:CGFloat(120+i*40))
                            .scaleEffect(particleBurst ? 1.6 : 1.0)
                            .opacity(particleBurst ? 0 : 1)
                            .animation(.easeOut(duration:1.2).delay(Double(i)*0.1), value:particleBurst)
                    }
                    Text("⬆️").font(.system(size:60))
                        .shadow(color:DS.gold.opacity(0.8), radius:20)
                }
                VStack(spacing:8) {
                    Text("LEVEL UP!").font(.system(size:36,weight:.black,design:.monospaced))
                        .foregroundStyle(LinearGradient(colors:[DS.gold, DS.green], startPoint:.leading, endPoint:.trailing))
                        .shadow(color:DS.gold.opacity(0.7), radius:12)
                    Text("You reached Level \(level)")
                        .font(.system(size:18,weight:.bold,design:.monospaced)).foregroundColor(.white)
                    Text("Keep pushing. The next level awaits.")
                        .font(.system(size:13)).foregroundColor(.white.opacity(0.6))
                }
                PressButton(action:{ dismiss() }) {
                    Text("CONTINUE").font(.system(size:16,weight:.black,design:.monospaced)).foregroundColor(.black)
                        .frame(width:200).padding(.vertical,14)
                        .background(LinearGradient(colors:[DS.gold, DS.green], startPoint:.leading, endPoint:.trailing))
                        .clipShape(RoundedRectangle(cornerRadius:16))
                        .shadow(color:DS.gold.opacity(0.5), radius:10)
                }
            }
            .scaleEffect(scale).opacity(opacity)
        }
        .onAppear {
            withAnimation(.spring(response:0.5, dampingFraction:0.65)) { scale = 1; opacity = 1 }
            withAnimation(.easeOut(duration:0.8).delay(0.3)) { particleBurst = true }
            UINotificationFeedbackGenerator().notificationOccurred(.success)
        }
    }

    func dismiss() {
        withAnimation(.easeIn(duration:0.25)) { scale = 0.8; opacity = 0 }
        DispatchQueue.main.asyncAfter(deadline:.now()+0.25) { onDismiss() }
    }
}

// MARK: - Image Picker
struct ImagePicker: UIViewControllerRepresentable {
    @Binding var image: UIImage?
    @Environment(\.dismiss) var dismiss

    func makeUIViewController(context:Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.delegate = context.coordinator
        picker.sourceType = .photoLibrary
        picker.allowsEditing = true
        return picker
    }
    func updateUIViewController(_ uiViewController:UIImagePickerController, context:Context) {}
    func makeCoordinator() -> Coordinator { Coordinator(self) }

    class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        let parent: ImagePicker
        init(_ parent: ImagePicker) { self.parent = parent }
        func imagePickerController(_ picker:UIImagePickerController, didFinishPickingMediaWithInfo info:[UIImagePickerController.InfoKey:Any]) {
            if let edited = info[.editedImage] as? UIImage { parent.image = edited }
            else if let original = info[.originalImage] as? UIImage { parent.image = original }
            parent.dismiss()
        }
        func imagePickerControllerDidCancel(_ picker:UIImagePickerController) { parent.dismiss() }
    }
}

// MARK: - Share Sheet
struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]
    func makeUIViewController(context:Context) -> UIActivityViewController {
        UIActivityViewController(activityItems:items, applicationActivities:nil)
    }
    func updateUIViewController(_ uiViewController:UIActivityViewController, context:Context) {}
}

// MARK: - LinearGradient Helper
extension LinearGradient {
    func asAnyView() -> AnyView { AnyView(self) }
}

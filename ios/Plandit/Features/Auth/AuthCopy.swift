import Foundation

/// Every string on the sign-in gate and the account section, from
/// docs/features/accounts-and-metrics/02-auth-copy.md. Change the doc first.
enum AuthCopy {
    // Welcome
    static let welcomeHeadline = "Turn the places you want to go into a real day."
    static let welcomeSubhead = "Send Plandit a TikTok or Reel of a spot. You get a plan that fits your budget and your time."
    static let continueWithEmail = "Continue with email"
    static let welcomeFootnote = "Free. No card needed. Your account keeps your places and plans if you switch phones."

    // Email form
    static let signUp = "Sign up"
    static let signIn = "Sign in"
    static let createYourAccount = "Create your account"
    static let welcomeBack = "Welcome back"
    static let name = "Name"
    static let email = "Email"
    static let password = "Password"
    static let passwordHint = "At least 8 characters"
    static let createAccount = "Create account"

    // Check your email
    static let checkYourEmail = "Check your email"
    static func checkEmailBody(_ email: String) -> String {
        "We sent a confirmation link to \(email). Tap it, then come back here and sign in."
    }
    static let checkEmailHint = "Don't see it? Check spam or promotions."
    static let resendEmail = "Resend email"

    // Inline errors
    static let invalidCredentials = "That email or password doesn't match."
    static func emailNotConfirmed(_ email: String) -> String {
        "Confirm your email first. We sent the link to \(email)."
    }
    static let userAlreadyExists = "An account with this email already exists. Sign in instead."
    static let weakPassword = "Use at least 8 characters."
    static let invalidEmail = "Enter a valid email."
    static let rateLimited = "We just sent you an email. Give it a minute, then try again."
    static let network = "Couldn't reach Plandit. Check your connection and try again."
    static let notConfigured = "This build isn't set up to sign in yet. Try updating the app."
    static let sessionExpired = "Your session ended. Sign in again. Your places and plans are still saved."
    static func resent(_ email: String) -> String { "Sent again to \(email)." }

    // Settings → Account
    static func signedInAs(_ email: String) -> String { "Signed in as \(email)" }
    static let signedInWithApple = "Signed in with Apple"
    static let signOut = "Sign out"
    static let deleteAccount = "Delete account"
    static let deleteTitle = "Delete your account?"
    static let deleteMessage = "This permanently removes your account, saved places and plans."

    // Not in the copy doc yet; needed for states it does not cover. Flagged for review.
    static let generic = "Something went wrong. Try again."
    static let deleteFailed = "We couldn't delete your account. Try again."

    static func message(for error: AuthError, email: String?) -> String {
        switch error {
        case .notConfigured: notConfigured
        case .invalidCredentials: invalidCredentials
        case .emailNotConfirmed: emailNotConfirmed(email ?? "your email")
        case .userAlreadyExists: userAlreadyExists
        case .weakPassword: weakPassword
        case .invalidEmail: invalidEmail
        case .emailRateLimited: rateLimited
        case .network: network
        case .sessionExpired, .accountMismatch: sessionExpired
        case .accountDeleted, .server, .invalidResponse: generic
        }
    }
}

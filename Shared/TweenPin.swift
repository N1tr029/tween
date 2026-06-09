import SwiftUI

/// The map annotation for endpoints (you, friend) and the fair midpoint. Built from
/// `Tokens.Palette` so a re-skin lands without touching call sites. The midpoint variant
/// is intentionally larger and uses a heavier shadow so it reads as the distinguished pick.
struct TweenPin: View {
    enum Role {
        case selfDot
        case friend
        case midpoint
    }

    let role: Role

    var body: some View {
        ZStack {
            Circle()
                .fill(tint.opacity(0.18))
                .frame(width: outerSize, height: outerSize)
            Circle()
                .fill(tint)
                .frame(width: innerSize, height: innerSize)
                .overlay {
                    Image(systemName: symbol)
                        .font(.system(size: iconSize, weight: .bold))
                        .foregroundStyle(.white)
                }
                .overlay {
                    Circle().stroke(.white, lineWidth: ringWidth)
                }
        }
        .tweenElevation(role == .midpoint ? Tokens.Elevation.floating : Tokens.Elevation.pin)
    }

    private var tint: Color {
        switch role {
        case .selfDot:  return Tokens.Palette.pinSelf
        case .friend:   return Tokens.Palette.pinFriend
        case .midpoint: return Tokens.Palette.pinMidpoint
        }
    }

    private var symbol: String {
        switch role {
        case .selfDot:  return "person.fill"
        case .friend:   return "person.2.fill"
        case .midpoint: return "star.fill"
        }
    }

    private var outerSize: CGFloat {
        role == .midpoint ? 58 : 48
    }

    private var innerSize: CGFloat {
        role == .midpoint ? 36 : 28
    }

    private var iconSize: CGFloat {
        role == .midpoint ? 14 : 11
    }

    private var ringWidth: CGFloat {
        role == .midpoint ? 5 : 4
    }
}

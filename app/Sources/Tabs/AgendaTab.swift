import SwiftUI
import WispCore

struct AgendaTab: View {
    let profile: Profile

    var body: some View {
        CalendarTab(profile: profile)
    }
}

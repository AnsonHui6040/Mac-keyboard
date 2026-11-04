import RemoteKeyboardCore
import SwiftUI

/// 「法律聲明」: disclaimer, rights and third-party notices. Not legal advice.
struct LegalView: View {
    var body: some View {
        List {
            Section("免責聲明") {
                Text(AppAbout.disclaimer)
                    .accessibilityIdentifier("rk.legal.disclaimer")
            }
            Section("權利聲明") {
                Text(AppAbout.rights)
                    .accessibilityIdentifier("rk.legal.rights")
            }
            Section("第三方聲明") {
                Text(AppAbout.thirdParty)
                    .accessibilityIdentifier("rk.legal.thirdParty")
            }
        }
        .navigationTitle("法律聲明")
    }
}

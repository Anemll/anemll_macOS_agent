import SwiftUI
import CoreGraphics
import ApplicationServices

struct ContentView: View {
    @EnvironmentObject var vm: HostViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {

            HStack {
                Text("Anemll Agent Host")
                    .font(.headline)
                Spacer()
                Circle()
                    .fill(vm.serverRunning ? .green : .red)
                    .frame(width: 10, height: 10)
                Text(vm.serverRunning ? "Running" : "Stopped")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Divider()

            Group {
                HStack {
                    Text("Screen Recording:")
                    Spacer()
                    Text(vm.screenCaptureAllowed ? "Allowed" : "Not allowed")
                        .foregroundStyle(vm.screenCaptureAllowed ? .green : .red)
                }
                HStack {
                    Text("Accessibility:")
                    Spacer()
                    Text(vm.accessibilityAllowed ? "Allowed" : "Not allowed")
                        .foregroundStyle(vm.accessibilityAllowed ? .green : .red)
                }
            }
            .font(.subheadline)

            HStack(spacing: 10) {
                Button("Request Screen Recording") {
                    vm.requestScreenCapture()
                }
                Button("Request Accessibility") {
                    vm.requestAccessibility()
                }
            }
            .font(.subheadline)

            HStack {
                Button("Reset Permissions") {
                    vm.resetPermissions()
                }
                Spacer()
            }
            .font(.subheadline)

            Divider()

            VStack(alignment: .leading, spacing: 6) {
                Text("Server")
                    .font(.subheadline)
                    .bold()

                Text("Listening on 127.0.0.1:8765")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                HStack {
                    Button(vm.serverRunning ? "Stop" : "Start") {
                        vm.serverRunning ? vm.stopServer() : vm.startServer()
                    }
                    Button("Rotate Token") {
                        vm.rotateToken()
                    }
                    Spacer()
                }

                Text("Bearer Token:")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Text(vm.token)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .padding(6)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color(nsColor: .windowBackgroundColor).opacity(0.6))
                    .cornerRadius(6)
            }

            Spacer()

            HStack {
                Button("Quit") { NSApp.terminate(nil) }
                Spacer()
                Text(vm.lastStatus)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        }
        .padding(12)
        .onAppear { vm.refreshPermissions() }
    }
}

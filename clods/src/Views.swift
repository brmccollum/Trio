import SwiftUI

struct ClodRow: View {
    let clod: Clod

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Circle().fill(Color.state(clod)).frame(width: 9, height: 9).padding(.top, 5)
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text(clod.name).font(.headline).lineLimit(1)
                    Spacer()
                    Text(ago(clod.updated)).font(.caption2).foregroundStyle(.secondary)
                }
                Text("\(clod.stateLabel) · \(clod.machine)")
                    .font(.caption2)
                    .foregroundStyle(clod.needsYou ? Color.state(clod) : .secondary)
                if !clod.detail.isEmpty {
                    Text(clod.detail).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                }
            }
        }
    }
}

struct ClodDetail: View {
    @EnvironmentObject var store: Store
    @Environment(\.dismiss) private var dismiss
    let clod: Clod
    @State private var reply = ""
    @State private var sending = false

    private var open: Bool { clod.askStatus == "open" && clod.askID != nil }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                Text("\(clod.stateLabel) · \(clod.machine) · \(ago(clod.updated))")
                    .font(.caption)
                    .foregroundStyle(Color.state(clod))

                if let ask = clod.ask, clod.askStatus != nil {
                    Text(ask).font(.body)
                } else if !clod.detail.isEmpty {
                    Text(clod.detail).font(.body)
                }

                if open {
                    Button {
                        send("go ahead")
                    } label: {
                        Label("Go ahead", systemImage: "checkmark.circle.fill").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.orange)
                    .disabled(sending)

                    TextField("Reply", text: $reply)
                        .onSubmit { if !reply.isEmpty { send(reply) } }
                    #if os(iOS)
                        .textFieldStyle(.roundedBorder)
                    #endif
                } else if clod.askStatus == "answered", let answer = clod.answer {
                    Label("Sent: \(answer)", systemImage: "paperplane")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text("Waiting for the session to pick it up.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                } else if clod.state == "permission" {
                    Text("Answer this one at the terminal.").font(.caption).foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .navigationTitle(clod.name)
    }

    private func send(_ text: String) {
        sending = true
        Task {
            await store.answer(clod, text)
            sending = false
            dismiss()
        }
    }
}

struct PairView: View {
    @EnvironmentObject var store: Store
    @State private var code = ""
    @State private var bad = false

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "link.circle").font(.largeTitle).foregroundStyle(.orange)
            #if os(watchOS)
                Text("Open Clods on your iPhone to pair.").multilineTextAlignment(.center)
            #else
                Text("Pair with your Mac").font(.title2.bold())
                Text("Point the Camera at the pairing code on the Mac, or paste the pairing link here.")
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
                TextField("Pairing link", text: $code)
                    .textFieldStyle(.roundedBorder)
                    .autocorrectionDisabled()
                Button("Pair") { bad = !store.pair(code) }
                    .buttonStyle(.borderedProminent)
                    .disabled(code.isEmpty)
                if bad { Text("That is not a pairing link.").font(.caption).foregroundStyle(.red) }
            #endif
        }
        .padding()
    }
}

struct RootView: View {
    @EnvironmentObject var store: Store

    var body: some View {
        if store.paired { ClodList() } else { PairView() }
    }
}

struct ClodList: View {
    @EnvironmentObject var store: Store
    @Environment(\.scenePhase) private var phase

    var body: some View {
        NavigationStack {
            List {
                if let error = store.error {
                    Text(error).font(.caption).foregroundStyle(.red)
                }
                let need = store.clods.filter(\.needsYou)
                let rest = store.clods.filter { !$0.needsYou }
                if !need.isEmpty {
                    Section("Needs you") {
                        ForEach(need) { clod in
                            NavigationLink(value: clod) { ClodRow(clod: clod) }
                        }
                    }
                }
                if !rest.isEmpty {
                    Section(need.isEmpty ? "Nothing waiting" : "Everything else") {
                        ForEach(rest) { clod in
                            NavigationLink(value: clod) { ClodRow(clod: clod) }
                        }
                    }
                }
                if store.clods.isEmpty, store.error == nil {
                    Text(store.lastLoad == nil ? "Loading…" : "No sessions have checked in yet.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Clods")
            .navigationDestination(for: Clod.self) { ClodDetail(clod: $0) }
            .refreshable { await store.load() }
        }
        .task(id: phase) {
            guard phase == .active else { return }
            while !Task.isCancelled {
                await store.load()
                try? await Task.sleep(for: .seconds(10))
            }
        }
    }
}

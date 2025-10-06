//
//  AppSettingsView.swift
//  Quizzie
//
//  Created by johannes Ringmark on 2025-10-05.
//

import SwiftUI
import Security

private enum Keys {
    static let offline = "offline_enabled"
    static let genAudio = "gen_audio_enabled"
    static let apiProvider = "api_provider"
    static let elevenLabs = "elevenlabs"
    static let apiKeyKC = "api_key"          // Keychain key
}

struct AppSettingsView: View {
    // Persisted booleans & picker via UserDefaults
    @AppStorage(Keys.offline)    private var offline = true      // default ON
    @AppStorage(Keys.genAudio)   private var genAudio = false
    @AppStorage(Keys.apiProvider) private var apiProvider = Keys.elevenLabs

    // Secure API key editing (lives in Keychain)
    @State private var apiKey: String = ""
    @State private var apiKeySaved: Bool = false
    @State private var revealKey = false

    private var generationEnabled: Bool { genAudio }
    private var needsApiKey: Bool { generationEnabled && apiProvider == Keys.elevenLabs }

    var body: some View {
        Form {
            Section("Mode") {
                Toggle("Offline Mode", isOn: $offline)
                Text("When Offline is ON, the app won’t call external APIs.")
                    .font(.footnote).foregroundStyle(.secondary)
            }

            if !offline{
                Section("TSS Provider") {
                    Toggle("Generate & Download Audio", isOn: $genAudio)
                        .disabled(offline)

                    Picker("Provider", selection: $apiProvider) {
                        Text("ElevenLabs").tag(Keys.elevenLabs)
                        // Add more providers later…
                    }
                    .disabled(offline)
                }
            }


            if needsApiKey {
                Section("API Credentials") {
                    HStack {
                        if revealKey {
                            TextField("API Key", text: $apiKey)
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled()
                        } else {
                            SecureField("API Key", text: $apiKey)
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled()
                        }
                        Button {
                            revealKey.toggle()
                        } label: {
                            Image(systemName: revealKey ? "eye.slash" : "eye")
                        }
                        .buttonStyle(.borderless)
                        .accessibilityLabel(revealKey ? "Hide API key" : "Show API key")
                    }

                    HStack {
                        Button("Save Key") { saveKey() }
                        if apiKeySaved {
                            Label("Saved", systemImage: "checkmark.circle")
                                .foregroundStyle(.green)
                        }
                        Spacer()
                        if !apiKey.isEmpty {
                            Button("Clear") { clearKey() }
                                .tint(.red)
                        }
                    }
                }
            }
        }
        .navigationTitle("Settings")
        .onAppear(perform: loadKey)
        .onChange(of: offline) { _ in pingStateResetIfNeeded() }
        .onChange(of: genAudio) { _ in pingStateResetIfNeeded() }
        .onChange(of: apiProvider) { _ in pingStateResetIfNeeded() }
    }

    // MARK: - Key handling

    private func loadKey() {
        //apiKey = Keychain.load(Keys.apiKeyKC) ?? ""
        apiKeySaved = !apiKey.isEmpty
    }

    private func saveKey() {
        do {
            if apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                clearKey()
                return
            }
            //try Keychain.save(apiKey, for: Keys.apiKeyKC)
            apiKeySaved = true
        } catch {
            apiKeySaved = false
            print("Keychain save failed: \(error)")
        }
    }
    
    
    @discardableResult
    func keychainSet(_ value: Data, for key: String) -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: key,
            kSecValueData as String: value
        ]
        SecItemDelete(query as CFDictionary)
        return SecItemAdd(query as CFDictionary, nil) == errSecSuccess
    }

    func keychainGet(_ key: String) -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: key,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        return status == errSecSuccess ? (item as? Data) : nil
    }

    private func clearKey() {
        //Keychain.delete(Keys.apiKeyKC)
        apiKey = ""
        apiKeySaved = false
    }

    private func pingStateResetIfNeeded() {
        // If user toggles back to Offline, we keep the key
        // but you can optionally clear transient UI flags here.
        //if !needsApiKey { apiKeySaved = !(Keychain.load(Keys.apiKeyKC) ?? "").isEmpty }
    }
}

#Preview {
    AppSettingsView()
}

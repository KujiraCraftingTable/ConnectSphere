import SwiftUI

struct ModeSelectionView: View {
    @Environment(AppState.self) var appState
    @Environment(\.appBundle) var bundle
    @State private var selectedMode: AppMode = .friend
    @State private var showNote = false
    @State private var appeared = false
    @State private var navigateToRegister = false

    var body: some View {
        ZStack {
            AppColors.base(.light).ignoresSafeArea()

            VStack(spacing: 0) {
                VStack(spacing: 10) {
                    Text("Bạn muốn dùng\nConnectSphere cho mục đích gì?", bundle: bundle)
                        .font(.system(size: 26, weight: .bold))
                        .foregroundColor(AppColors.textPrimary(.light))
                        .multilineTextAlignment(.center)
                    Text("Bạn có thể đổi chế độ sau trong cài đặt", bundle: bundle)
                        .font(.system(size: 14))
                        .foregroundColor(AppColors.textSecondary(.light))
                }
                .padding(.top, 60)
                .padding(.bottom, 40)
                .opacity(appeared ? 1 : 0)
                .offset(y: appeared ? 0 : 20)
                .animation(.easeOut(duration: 0.5).delay(0.1), value: appeared)

                VStack(spacing: 16) {
                    ModeOptionCard(
                        icon: "person.2.fill",
                        title: bundle.loc("Tìm bạn bè"),
                        subtitle: bundle.loc("Kết nối với người có cùng sở thích và đam mê"),
                        accentColor: Color(hex: "#FF6B35"),
                        isSelected: selectedMode == .friend
                    ) {
                        withAnimation(.spring(response: 0.3)) { selectedMode = .friend; showNote = true }
                    }

                    ModeOptionCard(
                        icon: "briefcase.fill",
                        title: bundle.loc("Tìm đồng nghiệp"),
                        subtitle: bundle.loc("Mở rộng mạng lưới chuyên nghiệp, tìm cộng tác viên và cơ hội nghề nghiệp"),
                        accentColor: Color(hex: "#1877F2"),
                        isSelected: selectedMode == .colleague
                    ) {
                        withAnimation(.spring(response: 0.3)) { selectedMode = .colleague; showNote = true }
                    }
                }
                .padding(.horizontal, 24)
                .opacity(appeared ? 1 : 0)
                .offset(y: appeared ? 0 : 30)
                .animation(.easeOut(duration: 0.5).delay(0.2), value: appeared)

                if showNote {
                    HStack(spacing: 8) {
                        Image(systemName: "info.circle.fill")
                            .foregroundColor(Color(hex: "#F7971E"))
                        Group {
                            Text(selectedMode == .friend
                                 ? "Bạn có thể thiết lập Chế độ Đồng nghiệp sau, hoặc "
                                 : "Bạn có thể thiết lập Chế độ Bạn bè sau, hoặc ", bundle: bundle)
                            + Text("thiết lập ngay →", bundle: bundle)
                                .bold()
                        }
                        .font(.system(size: 13))
                        .foregroundColor(AppColors.textSecondary(.light))
                    }
                    .padding(.horizontal, 28)
                    .padding(.top, 18)
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
                }

                Spacer()

                GradientButton(title: bundle.loc("Tiếp tục")) {
                    navigateToRegister = true
                }
                .padding(.horizontal, 24)
                .padding(.bottom, 40)
                .opacity(appeared ? 1 : 0)
                .animation(.easeOut(duration: 0.5).delay(0.3), value: appeared)
            }
        }
        .navigationBarTitleDisplayMode(.inline)
        .navigationDestination(isPresented: $navigateToRegister) {
            RegisterView(selectedMode: selectedMode)
        }
        .onAppear { appeared = true }
        .preferredColorScheme(.light)
    }
}

// MARK: - Mode Option Card

private struct ModeOptionCard: View {
    let icon: String
    let title: String
    let subtitle: String
    let accentColor: Color
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 16) {
                ZStack {
                    Circle()
                        .fill(isSelected ? accentColor : accentColor.opacity(0.15))
                        .frame(width: 52, height: 52)
                    Image(systemName: icon)
                        .font(.system(size: 22))
                        .foregroundColor(isSelected ? .white : accentColor)
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text(title)
                        .font(.system(size: 17, weight: .bold))
                        .foregroundColor(AppColors.textPrimary(.light))
                    Text(subtitle)
                        .font(.system(size: 13))
                        .foregroundColor(AppColors.textSecondary(.light))
                        .multilineTextAlignment(.leading)
                }

                Spacer()

                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 22))
                    .foregroundColor(isSelected ? accentColor : .white.opacity(0.3))
            }
            .padding(20)
            .background(
                RoundedRectangle(cornerRadius: 18)
                    .fill(isSelected ? AppColors.stateSelected(.light) : AppColors.stateHover(.light))
                    .overlay(
                        RoundedRectangle(cornerRadius: 18)
                            .stroke(isSelected ? accentColor.opacity(0.7) : AppColors.borderDefault(.light), lineWidth: 1.5)
                    )
            )
        }
        .buttonStyle(.plain)
    }
}

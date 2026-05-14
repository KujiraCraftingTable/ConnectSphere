//
//  ConnectSphereApp.swift
//  ConnectSphere
//
//  Created by Trị Minh on 14/5/26.
//

import SwiftUI
import CoreData

@main
struct ConnectSphereApp: App {
    let persistenceController = PersistenceController.shared

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(\.managedObjectContext, persistenceController.container.viewContext)
        }
    }
}

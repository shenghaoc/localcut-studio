import Foundation
import LocalCutCore

// MARK: - Program scene intents

extension EditorModel {
    func addProgramScene(_ scene: SceneDefinition) {
        performUndoable("Add Program Scene") {
            var doc = project.sceneDoc
            doc.scenes.append(scene)
            project.sceneDoc = migrateSceneDoc(doc)
            statusMessage = "Added program scene \(scene.name)."
        }
    }

    func updateProgramScene(_ scene: SceneDefinition) {
        performUndoable("Edit Program Scene") {
            var doc = project.sceneDoc
            guard let index = doc.scenes.firstIndex(where: { $0.id == scene.id }) else { return }
            doc.scenes[index] = scene
            project.sceneDoc = migrateSceneDoc(doc)
            statusMessage = "Updated program scene \(scene.name)."
        }
    }

    func deleteProgramScene(id: UUID) {
        performUndoable("Delete Program Scene") {
            var doc = project.sceneDoc
            guard let scene = doc.scenes.first(where: { $0.id == id }) else { return }
            doc.scenes.removeAll { $0.id == id }
            project.sceneDoc = migrateSceneDoc(doc)
            statusMessage = "Deleted program scene \(scene.name)."
        }
    }
}

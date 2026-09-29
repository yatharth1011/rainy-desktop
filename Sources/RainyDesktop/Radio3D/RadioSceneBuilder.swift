import SceneKit
import AppKit

/// Builds a small procedural "retro radio" 3D model: a body with a glowing
/// screen that shows the current track's artwork, a spinning vinyl disc on
/// top (its label also carries the artwork), speaker grilles, and an antenna.
/// No external assets required -- everything is generated geometry + textures.
enum RadioSceneBuilder {
    struct Nodes {
        let scene: SCNScene
        let screenPlane: SCNNode
        let vinylGroup: SCNNode
        let vinylLabel: SCNNode
        let cameraNode: SCNNode
    }

    static func build() -> Nodes {
        let scene = SCNScene()
        scene.background.contents = NSColor.clear

        let root = SCNNode()
        scene.rootNode.addChildNode(root)

        // Body
        let body = SCNBox(width: 2.3, height: 1.35, length: 1.0, chamferRadius: 0.12)
        let bodyMaterial = SCNMaterial()
        bodyMaterial.diffuse.contents = NSColor(calibratedRed: 0.11, green: 0.12, blue: 0.16, alpha: 1)
        bodyMaterial.roughness.contents = 0.45
        bodyMaterial.metalness.contents = 0.15
        body.materials = [bodyMaterial]
        let bodyNode = SCNNode(geometry: body)
        root.addChildNode(bodyNode)

        // Screen (shows artwork)
        let screen = SCNPlane(width: 1.35, height: 0.78)
        screen.cornerRadius = 0.05
        let screenMaterial = SCNMaterial()
        screenMaterial.diffuse.contents = placeholderArtwork()
        screenMaterial.emission.contents = NSColor(white: 0.08, alpha: 1)
        screenMaterial.lightingModel = .constant
        screen.materials = [screenMaterial]
        let screenNode = SCNNode(geometry: screen)
        screenNode.position = SCNVector3(0, 0.05, 0.51)
        bodyNode.addChildNode(screenNode)

        // Speaker grilles
        for side: Float in [-1, 1] {
            let grille = SCNCylinder(radius: 0.16, height: 0.06)
            let mat = SCNMaterial()
            mat.diffuse.contents = grilleTexture()
            mat.roughness.contents = 0.7
            mat.metalness.contents = 0.3
            grille.materials = [mat]
            let node = SCNNode(geometry: grille)
            node.eulerAngles = SCNVector3(Float.pi / 2, 0, 0)
            node.position = SCNVector3(side * 0.92, -0.15, 0.5)
            bodyNode.addChildNode(node)
        }

        // Antenna
        let antenna = SCNCylinder(radius: 0.014, height: 1.05)
        let antennaMaterial = SCNMaterial()
        antennaMaterial.diffuse.contents = NSColor(calibratedWhite: 0.75, alpha: 1)
        antennaMaterial.metalness.contents = 0.9
        antennaMaterial.roughness.contents = 0.2
        antenna.materials = [antennaMaterial]
        let antennaNode = SCNNode(geometry: antenna)
        antennaNode.position = SCNVector3(0.95, 0.9, -0.2)
        antennaNode.eulerAngles = SCNVector3(0, 0, Float.pi / 10)
        bodyNode.addChildNode(antennaNode)

        // Vinyl disc on top
        let vinylGroup = SCNNode()
        vinylGroup.position = SCNVector3(0, 0.72, 0)
        bodyNode.addChildNode(vinylGroup)

        let disc = SCNCylinder(radius: 0.56, height: 0.035)
        let discMaterial = SCNMaterial()
        discMaterial.diffuse.contents = vinylGrooveTexture()
        discMaterial.roughness.contents = 0.25
        discMaterial.metalness.contents = 0.05
        disc.materials = [discMaterial]
        let discNode = SCNNode(geometry: disc)
        vinylGroup.addChildNode(discNode)

        let label = SCNCylinder(radius: 0.19, height: 0.045)
        let labelMaterial = SCNMaterial()
        labelMaterial.diffuse.contents = placeholderArtwork()
        labelMaterial.roughness.contents = 0.6
        label.materials = [labelMaterial]
        let labelNode = SCNNode(geometry: label)
        labelNode.position = SCNVector3(0, 0.006, 0)
        vinylGroup.addChildNode(labelNode)

        // Lighting
        let key = SCNLight()
        key.type = .directional
        key.intensity = 900
        key.color = NSColor(calibratedRed: 0.85, green: 0.9, blue: 1.0, alpha: 1)
        let keyNode = SCNNode()
        keyNode.light = key
        keyNode.eulerAngles = SCNVector3(-Float.pi / 4, Float.pi / 5, 0)
        root.addChildNode(keyNode)

        let ambient = SCNLight()
        ambient.type = .ambient
        ambient.intensity = 220
        ambient.color = NSColor(calibratedWhite: 1, alpha: 1)
        let ambientNode = SCNNode()
        ambientNode.light = ambient
        root.addChildNode(ambientNode)

        // Camera, slight 3/4 angle
        let camera = SCNCamera()
        camera.fieldOfView = 32
        let cameraNode = SCNNode()
        cameraNode.camera = camera
        cameraNode.position = SCNVector3(1.6, 1.15, 3.1)
        cameraNode.look(at: SCNVector3(0, 0.1, 0))
        root.addChildNode(cameraNode)

        root.eulerAngles = SCNVector3(0, -0.12, 0)
        let sway = SCNAction.sequence([
            .rotateBy(x: 0, y: 0.14, z: 0, duration: 6),
            .rotateBy(x: 0, y: -0.28, z: 0, duration: 12),
            .rotateBy(x: 0, y: 0.14, z: 0, duration: 6)
        ])
        root.runAction(.repeatForever(sway))

        return Nodes(scene: scene, screenPlane: screenNode, vinylGroup: vinylGroup, vinylLabel: labelNode, cameraNode: cameraNode)
    }

    static func setSpinning(_ nodes: Nodes, spinning: Bool, speed: Float = 1.0) {
        let key = "vinylSpin"
        if spinning {
            nodes.vinylGroup.removeAction(forKey: key)
            let duration = 2.2 / Double(max(speed, 0.05))
            let spin = SCNAction.rotateBy(x: 0, y: -.pi * 2, z: 0, duration: duration)
            nodes.vinylGroup.runAction(.repeatForever(spin), forKey: key)
        } else {
            nodes.vinylGroup.removeAction(forKey: key)
        }
    }

    static func updateArtwork(_ nodes: Nodes, image: NSImage?) {
        let content: Any = image ?? placeholderArtwork()
        nodes.screenPlane.geometry?.firstMaterial?.diffuse.contents = content
        nodes.vinylLabel.geometry?.firstMaterial?.diffuse.contents = content
    }

    private static func placeholderArtwork() -> NSImage {
        let size = NSSize(width: 256, height: 256)
        let image = NSImage(size: size)
        image.lockFocus()
        let gradient = NSGradient(colors: [
            NSColor(calibratedRed: 0.16, green: 0.18, blue: 0.26, alpha: 1),
            NSColor(calibratedRed: 0.05, green: 0.06, blue: 0.1, alpha: 1)
        ])
        gradient?.draw(in: NSRect(origin: .zero, size: size), angle: 45)
        let symbolRect = NSRect(x: 88, y: 88, width: 80, height: 80)
        NSColor(calibratedWhite: 1, alpha: 0.18).setFill()
        NSBezierPath(ovalIn: symbolRect).fill()
        image.unlockFocus()
        return image
    }

    private static func grilleTexture() -> NSImage {
        let size = NSSize(width: 128, height: 128)
        let image = NSImage(size: size)
        image.lockFocus()
        NSColor(calibratedWhite: 0.08, alpha: 1).setFill()
        NSRect(origin: .zero, size: size).fill()
        NSColor(calibratedWhite: 0.35, alpha: 1).setFill()
        let spacing: CGFloat = 14
        var y: CGFloat = 6
        while y < size.height {
            var x: CGFloat = 6
            while x < size.width {
                NSBezierPath(ovalIn: NSRect(x: x, y: y, width: 6, height: 6)).fill()
                x += spacing
            }
            y += spacing
        }
        image.unlockFocus()
        return image
    }

    private static func vinylGrooveTexture() -> NSImage {
        let size = NSSize(width: 256, height: 256)
        let image = NSImage(size: size)
        image.lockFocus()
        NSColor(calibratedWhite: 0.03, alpha: 1).setFill()
        NSRect(origin: .zero, size: size).fill()
        let center = NSPoint(x: 128, y: 128)
        var radius: CGFloat = 20
        while radius < 126 {
            let alpha = 0.12 + 0.06 * sin(radius)
            NSColor(calibratedWhite: 0.5, alpha: max(alpha, 0.04)).setStroke()
            let path = NSBezierPath(ovalIn: NSRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2))
            path.lineWidth = 1
            path.stroke()
            radius += 3
        }
        image.unlockFocus()
        return image
    }
}

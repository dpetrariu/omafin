import QtQuick

// A wide picture that fades into the window's background at the bottom and
// the left, so text over it stays readable in any theme.
Item {
  id: root
  required property var theme
  required property var service
  property var image: null
  property real requestWidth: 1920
  property real dim: 0.35

  clip: true

  Image {
    id: picture
    anchors.fill: parent
    source: root.service.imageUrl(root.image, "Backdrop", root.requestWidth)
    fillMode: Image.PreserveAspectCrop
    verticalAlignment: Image.AlignTop
    asynchronous: true
    sourceSize.width: root.requestWidth
    opacity: status === Image.Ready ? 1 : 0
    Behavior on opacity { NumberAnimation { duration: 300 } }
  }
  Rectangle {
    anchors.fill: parent
    color: Qt.rgba(root.theme.background.r, root.theme.background.g, root.theme.background.b, root.dim)
  }
  Rectangle {
    anchors.fill: parent
    gradient: Gradient {
      orientation: Gradient.Horizontal
      GradientStop { position: 0; color: root.theme.alpha(root.theme.background, 0.92) }
      GradientStop { position: 0.55; color: root.theme.alpha(root.theme.background, 0.25) }
      GradientStop { position: 1; color: root.theme.alpha(root.theme.background, 0) }
    }
  }
  Rectangle {
    anchors.fill: parent
    gradient: Gradient {
      GradientStop { position: 0.45; color: root.theme.alpha(root.theme.background, 0) }
      GradientStop { position: 1; color: root.theme.background }
    }
  }
}

import PDFKit

extension AnnotationPDFView {
    /// PDFKit draws each custom-drawn annotation (a formula) in a layer of its
    /// own and doesn't take that layer away when the annotation leaves its
    /// page, so moved, edited and deleted formulas would stay on screen as
    /// ghosts. This removes the layers of annotations that are no longer on a
    /// page. The layers are PDFKit internals: every step is checked, and if
    /// they change this does nothing.
    func removeLayersOfRemovedAnnotations() {
        let annotationSelector = NSSelectorFromString("annotation")
        let idSelector = NSSelectorFromString("UUID")
        let removeSelector = NSSelectorFromString(
            "removePageLayerEffectForID:")
        func visit(_ layer: CALayer, pageLayer: CALayer?) {
            let pageLayer =
                layer.responds(to: removeSelector) ? layer : pageLayer
            for sublayer in layer.sublayers ?? [] {
                visit(sublayer, pageLayer: pageLayer)
            }
            guard
                NSStringFromClass(Swift.type(of: layer)).hasSuffix(
                    "AnnotationEffect"),
                layer.responds(to: annotationSelector),
                let annotation = layer.perform(annotationSelector)?
                    .takeUnretainedValue() as? PDFAnnotation,
                annotation.page == nil
            else { return }
            // Through the page layer, so PDFKit forgets the layer too.
            if let pageLayer, layer.responds(to: idSelector),
                let id = layer.perform(idSelector)?.takeUnretainedValue()
            {
                pageLayer.perform(removeSelector, with: id)
            }
            if layer.superlayer != nil { layer.removeFromSuperlayer() }
        }
        if let layer { visit(layer, pageLayer: nil) }
    }
}

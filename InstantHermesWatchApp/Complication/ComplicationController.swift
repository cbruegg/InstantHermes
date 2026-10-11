//
//  ComplicationController.swift
//  InstantHermesWatchApp
//
//  Created by Christian Brüggemann on 11.10.26.
//

import ClockKit
import SwiftUI

/// Provides a simple complication that launches the app when tapped.
/// Registered via `CLKComplicationPrincipalClass` in the watch app's Info.plist.
final class ComplicationController: NSObject, CLKComplicationDataSource {

    // MARK: - Timeline Configuration

    func getSupportedTimeTravelDirections(
        for complication: CLKComplication,
        withHandler handler: @escaping (CLKComplicationTimeTravelDirections) -> Void
    ) {
        // No time travel — this complication is static
        handler([])
    }

    func getTimelineStartDate(
        for complication: CLKComplication,
        withHandler handler: @escaping (Date?) -> Void
    ) {
        handler(nil)
    }

    func getTimelineEndDate(
        for complication: CLKComplication,
        withHandler handler: @escaping (Date?) -> Void
    ) {
        handler(nil)
    }

    func getPrivacyBehavior(
        for complication: CLKComplication,
        withHandler handler: @escaping (CLKComplicationPrivacyBehavior) -> Void
    ) {
        handler(.showOnLockScreen)
    }

    // MARK: - Timeline Population

    func getCurrentTimelineEntry(
        for complication: CLKComplication,
        withHandler handler: @escaping (CLKComplicationTimelineEntry?) -> Void
    ) {
        handler(createTimelineEntry(for: complication, date: Date()))
    }

    func getTimelineEntries(
        for complication: CLKComplication,
        after date: Date,
        limit: Int,
        withHandler handler: @escaping ([CLKComplicationTimelineEntry]?) -> Void
    ) {
        // Static complication — no future entries needed
        handler(nil)
    }

    // MARK: - Placeholder Templates

    func getLocalizableSampleTemplate(
        for complication: CLKComplication,
        withHandler handler: @escaping (CLKComplicationTemplate?) -> Void
    ) {
        handler(createTemplate(for: complication))
    }

    // MARK: - Complication Descriptors

    func getComplicationDescriptors(handler: @escaping ([CLKComplicationDescriptor]) -> Void) {
        let families: [CLKComplicationFamily] = [
            .graphicCorner,
            .graphicBezel,
            .graphicCircular,
            .graphicRectangular,
            .graphicExtraLarge,
            .modularSmall,
            .modularLarge,
            .utilitarianSmall,
            .utilitarianSmallFlat,
            .utilitarianLarge,
            .circularSmall,
            .extraLarge,
        ]

        // This is one complication with multiple layouts, not one identity per family.
        handler([
            CLKComplicationDescriptor(
                identifier: "com.cbruegg.InstantHermes.complication.launch",
                displayName: "InstantHermes",
                supportedFamilies: families
            )
        ])
    }

    // MARK: - Private Helpers

    private func createTimelineEntry(
        for complication: CLKComplication,
        date: Date
    ) -> CLKComplicationTimelineEntry? {
        guard let template = createTemplate(for: complication) else { return nil }
        return CLKComplicationTimelineEntry(date: date, complicationTemplate: template)
    }

    private func createTemplate(for complication: CLKComplication) -> CLKComplicationTemplate? {
        // Keep the template family correct even when the bundled artwork is unavailable.
        guard let image = UIImage(named: "ComplicationIcon")
            ?? UIImage(systemName: "mic.fill") else { return nil }
        let fullColorImageProvider = CLKFullColorImageProvider(
            fullColorImage: image.withRenderingMode(.alwaysOriginal),
            tintedImageProvider: CLKImageProvider(onePieceImage: image)
        )

        switch complication.family {
        // MARK: Graphic Families (use CLKFullColorImageProvider)
        case .graphicCorner:
            let template = CLKComplicationTemplateGraphicCornerCircularImage()
            template.imageProvider = fullColorImageProvider
            return template

        case .graphicBezel:
            let circular = CLKComplicationTemplateGraphicCircularImage()
            circular.imageProvider = fullColorImageProvider
            let template = CLKComplicationTemplateGraphicBezelCircularText(
                circularTemplate: circular,
                textProvider: CLKSimpleTextProvider(text: "Hermes")
            )
            return template

        case .graphicCircular:
            let template = CLKComplicationTemplateGraphicCircularImage()
            template.imageProvider = fullColorImageProvider
            return template

        case .graphicRectangular:
            let template = CLKComplicationTemplateGraphicRectangularStandardBody()
            template.headerImageProvider = fullColorImageProvider
            template.headerTextProvider = CLKSimpleTextProvider(text: "InstantHermes")
            template.body1TextProvider = CLKSimpleTextProvider(text: "Tap to record")
            return template

        case .graphicExtraLarge:
            let template = CLKComplicationTemplateGraphicExtraLargeCircularImage()
            template.imageProvider = fullColorImageProvider
            return template

        // MARK: Modular Families (use CLKImageProvider)
        case .modularSmall:
            let template = CLKComplicationTemplateModularSmallSimpleImage()
            template.imageProvider = CLKImageProvider(onePieceImage: image)
            return template

        case .modularLarge:
            let template = CLKComplicationTemplateModularLargeStandardBody()
            template.headerTextProvider = CLKSimpleTextProvider(text: "InstantHermes")
            template.body1TextProvider = CLKSimpleTextProvider(text: "Tap to record")
            return template

        // MARK: Utilitarian Families (use CLKImageProvider)
        case .utilitarianSmall:
            let template = CLKComplicationTemplateUtilitarianSmallSquare()
            template.imageProvider = CLKImageProvider(onePieceImage: image)
            return template

        case .utilitarianSmallFlat:
            let template = CLKComplicationTemplateUtilitarianSmallFlat()
            template.imageProvider = CLKImageProvider(onePieceImage: image)
            template.textProvider = CLKSimpleTextProvider(text: "Hermes")
            return template

        case .utilitarianLarge:
            let template = CLKComplicationTemplateUtilitarianLargeFlat()
            template.imageProvider = CLKImageProvider(onePieceImage: image)
            template.textProvider = CLKSimpleTextProvider(text: "InstantHermes")
            return template

        // MARK: Circular Families (use CLKImageProvider)
        case .circularSmall:
            let template = CLKComplicationTemplateCircularSmallSimpleImage()
            template.imageProvider = CLKImageProvider(onePieceImage: image)
            return template

        case .extraLarge:
            let template = CLKComplicationTemplateExtraLargeSimpleImage()
            template.imageProvider = CLKImageProvider(onePieceImage: image)
            return template

        @unknown default:
            return nil
        }
    }
}

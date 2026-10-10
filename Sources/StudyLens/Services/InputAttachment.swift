import Foundation
import ImageIO
import UniformTypeIdentifiers

enum InputValidationError: LocalizedError, Equatable {
    case selectionTooLong, instructionsTooLong, unsupportedImageModel, imageTooLarge, invalidImage
    var errorDescription: String? {
        switch self {
        case .selectionTooLong: return "선택 본문은 비어 있지 않은 30,000자 이하의 텍스트여야 합니다."
        case .instructionsTooLong: return "추가 지시는 2,000자 이하로 입력해 주세요."
        case .unsupportedImageModel: return "이 모델의 이미지 입력 지원을 확인하지 못했습니다. 그림 첨부를 끄거나 이미지 지원이 확인된 모델을 선택하세요."
        case .imageTooLarge: return "그림 첨부는 PNG 한 장, 10 MiB 이하로 제한합니다. 더 작은 영역을 선택해 주세요."
        case .invalidImage: return "첨부할 PNG 이미지를 읽지 못했습니다. 그림 영역을 다시 선택해 주세요."
        }
    }
}

enum InputAttachment {
    static let maximumBytes = 10 * 1024 * 1024
    static func validate(text: String, additionalInstructions: String) throws {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, text.count <= 30_000 else { throw InputValidationError.selectionTooLong }
        guard additionalInstructions.count <= 2_000 else { throw InputValidationError.instructionsTooLong }
    }

    static func validate(image: Data, model: String) throws {
        guard ModelCapabilities.imageInput.contains(model) else { throw InputValidationError.unsupportedImageModel }
        guard image.count <= maximumBytes else { throw InputValidationError.imageTooLarge }
        guard !image.isEmpty, let source = CGImageSourceCreateWithData(image as CFData, nil),
              CGImageSourceGetType(source) as String? == UTType.png.identifier,
              CGImageSourceGetCount(source) == 1,
              CGImageSourceCreateImageAtIndex(source, 0, nil) != nil else { throw InputValidationError.invalidImage }
    }
}

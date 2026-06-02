import AuthenticationServices

class CredentialProviderViewController: ASCredentialProviderViewController {

    override func prepareCredentialList(for serviceIdentifiers: [ASCredentialServiceIdentifier]) {
        extensionContext.cancelRequest(withError: NSError(
            domain: ASExtensionErrorDomain,
            code: ASExtensionError.userCanceled.rawValue
        ))
    }

    override func prepareInterfaceForExtensionConfiguration() {
        extensionContext.completeExtensionConfigurationRequest()
    }
}

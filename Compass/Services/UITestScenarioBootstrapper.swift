//
//  UITestScenarioBootstrapper.swift
//  Compass
//
//  Created by AI Assistant on 20/05/2026.
//

import Foundation

/// Handles setting up the application state for specific UI testing scenarios.
@MainActor
enum UITestScenarioBootstrapper {
    
    /// Bootstraps the application state if running a UI test with a specific scenario.
    static func bootstrapIfNeeded(appState: AppState, launchContext: AppLaunchContext) {
        guard launchContext.isUITesting,
              let scenario = ProcessInfo.processInfo.environment[TestLaunchKeys.uiTestScenario] else {
            return
        }
        
        switch scenario {
        case "json_highlighting":
            let json = """
            {
              "key": "value",
              "number": 123,
              "bool": true,
              "nullVal": null,
              "arr": [1, false],
              "obj": {"nested": false}
            }
            """
            appState.fileEditor.primaryPane.editorContent = json
            appState.fileEditor.primaryPane.editorLanguage = "json"
            
        case "typescript_highlighting":
            let typescript = """
            interface User {
              id: number
              name: string
            }

            const getUser = async (id: number): Promise<User> => {
              // load user
              const response = await fetch(`/users/${id}`)
              return response.json() as Promise<User>
            }
            """
            appState.fileEditor.primaryPane.editorContent = typescript
            appState.fileEditor.primaryPane.editorLanguage = "typescript"
            
        case "typescript_realworld_highlighting":
            let typescriptRealWorld = """
            import React, { useState } from 'react'

            interface PasswordRecoveryProps {
              onBackToLogin: () => void
              onPasswordRecovery?: (email: string) => void
            }

            const PasswordRecovery: React.FC<PasswordRecoveryProps> = ({
              onBackToLogin,
              onPasswordRecovery
            }) => {
              const [email, setEmail] = useState('')
              const [emailError, setEmailError] = useState('')
              const [isSubmitting, setIsSubmitting] = useState(false)

              // Simulate API call
              const validateForm = () => {
                if (!email) {
                  setEmailError('Email is required')
                  return false
                }
                return true
              }
            }
            """
            appState.fileEditor.primaryPane.editorContent = typescriptRealWorld
            appState.fileEditor.primaryPane.editorLanguage = "typescript"
            
        case "tsx_realworld_highlighting":
            let tsx = """
            import React from 'react'

            interface PasswordRecoveryProps {
              onBackToLogin: () => void
              onPasswordRecovery: (email: string) => void
            }

            export const PasswordRecovery: React.FC<PasswordRecoveryProps> = ({
              onBackToLogin,
              onPasswordRecovery
            }) => {
              const handlePasswordRecovery = (email: string) => {
                // In a real app, this would call the password recovery API
                console.log('Password recovery requested for:', email)
              }

              return (
                <div className="app-shell">
                  <PasswordRecoveryForm
                    onBackToLogin={onBackToLogin}
                    onPasswordRecovery={handlePasswordRecovery}
                  />
                </div>
              )
            }
            """
            appState.fileEditor.primaryPane.editorContent = tsx
            appState.fileEditor.primaryPane.editorLanguage = "tsx"
            
        default:
            break
        }
    }
}

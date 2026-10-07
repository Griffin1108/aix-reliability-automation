// Windows learning lab. Configure this job as "Pipeline script from SCM".
pipeline {
    agent any

    options {
        skipDefaultCheckout(true)
        disableConcurrentBuilds()
        timeout(time: 10, unit: 'MINUTES')
    }

    environment {
        // Temporary lab dependency: replace with a dedicated Python installation later.
        PYTHON_EXE = 'C:\\Users\\tkamb\\.cache\\codex-runtimes\\codex-primary-runtime\\dependencies\\python\\python.exe'
        AIX_TEST_BASH = 'C:\\Program Files\\Git\\bin\\bash.exe'
    }

    stages {
        stage('Welcome') {
            steps {
                echo 'My AIX reliability pipeline has started!'
            }
        }

        stage('Checkout') {
            steps {
                // Use the same repository and revision that supplied this Jenkinsfile.
                checkout scm
            }
        }

        stage('Check tools') {
            steps {
                script {
                    if (isUnix()) {
                        error('This Jenkinsfile is for the Windows learning lab.')
                    }
                }
                bat '''
@echo off
"%PYTHON_EXE%" --version
if errorlevel 1 exit /b 1
"%AIX_TEST_BASH%" --version
if errorlevel 1 exit /b 1
'''
            }
        }

        stage('Tests') {
            steps {
                bat '''
@echo off
"%PYTHON_EXE%" -m unittest discover -s tests -v > "all-tests-%BUILD_NUMBER%.txt" 2>&1
set "TEST_EXIT=%ERRORLEVEL%"
type "all-tests-%BUILD_NUMBER%.txt"
exit /b %TEST_EXIT%
'''
            }
            post {
                always {
                    archiveArtifacts(
                        artifacts: "all-tests-${env.BUILD_NUMBER}.txt",
                        allowEmptyArchive: false
                    )
                }
            }
        }
    }
}

##  A Perl script to download and display all the messages from a POP3 email account. This code was written and verified by Michael J. Ross (www.ross.ws) sometime during 1999-2000. However, it may since have been rendered inoperable due to any subsequent changes to Perl and the CPAN modules it uses.

##  Define the pragmas.
use strict 'vars';

##  Include the needed modules.
use MIME::Base64;
use Net::POP3;

##  Set the email account values, to replace the dummy values listed here.
my $server = 'server';
my $account = 'account';
my $password = 'password';
my $messages;
my $error;
mail_get_messages( $server, $account, $password, '', '', $messages, $error );
mail_show_messages( $messages );

exit 0;

sub mail_get_messages {
    ##  Get all the email messages from the in-box.

    ##  Function arguments:
    ##      $_[ 0 ] = The name of the POP3 mail server.
    ##      $_[ 1 ] = The account name on the mail server.
    ##      $_[ 2 ] = The password for the account.
    ##      $_[ 3 ] = The subject filter. If it is not null, then only process the messages that match the filter. The filter can be a regular expression.
    ##      $_[ 4 ] = A deletion flag. If it is not null, then delete the messages from the server.
    ##      $_[ 5 ] = This is set to a reference to an array of hash references, one for each message. The hash keys are Date, From, To, Subject, Content, Files.
    ##                The Files value is a reference to the array, one for each attached file. The array element is a reference to the hash, keyed by Text and
    ##                Name. The Text value is the file content, decoded from Base64 MIME if needed. The Name value is the file name.
    ##      $_[ 6 ] = This is set to a message indicating success or any error.

    my ( $server, $account, $password, $subject_filter, $delete_message ) = @_[ 0..4 ];

    ##  Construct the Net::POP3 object to connect to the remote POP3 mail server.
    my $pop;
    if ( ! $pop = Net::POP3->new( $server ) ) {
        $_[ 6 ] = "Error: Cannot connect to mail server $server.";
        return 0;
    }

    ##  Login to the mail server and check the number of undeleted messages. One possibility is to encrypt the password using MD5 apop() instead of login().
    my $num_messages = $pop->login( $account, $password );

    if ( ! defined $num_messages ) {
        $_[ 6 ] = "Error: Cannot login to $account\@$server; message returned: $!";
        return 0;
    }
    elsif ( $num_messages == 0 ) {
        $_[ 6 ] = "Error: No messages in $account\@$server account";
        return 0;
    }

    ##  Fetch the list of messages in the account.
    my $messages_list;
    if ( ! $messages_list = $pop->list ) {
        $_[ 6 ] = "Error: Cannot get mail messages in $account\@$server account";
        return 0;
    }

    ##  Process each message and add it to the hash.
    my $message_num = 0;
    foreach my $message_id ( keys %$messages_list ) {
        ##  Get the message. $pop->get() returns a reference to the array.
        my $message_text = $pop->get( $message_id );
        if ( ! defined $message_text ) {
            $_[ 6 ] = "Error: Cannot get message $message_id in $account\@$server";
            return 0;
        }

        ##  Get the header elements of the message. Use the first 100 lines in case the message was forwarded many times (since each forwarding pushes the subject down three lines). Search for the subject separately because the subject heading is not included if the subject was blank.
        my @sub_message = @$message_text[ 0..99 ];    ##  Cannot reference the array range.
        my $sub_text = string_from_array_ref( \@sub_message );

        my $subject = '';
        if ( $sub_text =~ m!\nSubject: (.+?)\n! ) {
            $subject = $1;
            if ( ( "$subject_filter" ne '' ) && ( $subject !~ m!$subject_filter! ) ) {
                next;    ##  The subject does not match the subject filter.
            }
        }

        ##  Search for the date and mail addresses separately, in case one or two are not found, for whatever reason.
        $sub_text =~ m!\nDate: (.*?)\n!;
        my $date = $1;
        $sub_text =~ m!\nFrom: (.*?)\n!;
        my $from = $1;
        $sub_text =~ m!To: (.*?)\n!;
        my $to = $1;
        $sub_text =~ m!Received: from (.*?)\n.*\n[ \t]+for <(.*?)>; !s;
        my $domain = $1;
        my $received = $2;

        ##  Put the header elements in the hash.
        my %message;
        $message{Subject} = $subject;
        if ( defined $date ) {
            $message{Date} = $date;
        }
        if ( defined $from ) {
            $message{From} = $from;
        }
        if ( ( defined $to ) && ( $to ne '' ) ) {
            $message{To} = $to;
        } elsif ( ( defined $received ) && ( $received ne '' ) ) {
            $message{To} = $received;
            if ( ( defined $domain ) && ( $domain ne '' ) ) {
                $message{To} .= $domain;
            }
        }

        ##  If the message is not multi-part, then it has no attached file(s).
        my $text = string_from_array_ref( $message_text );

        if ( $text !~ m!\nThis is a multi-part message in MIME format.\n! ) {
            ##  Get the content of the message from the text.
            $text =~ s!^.*\nContent-Length:.*?\nStatus:.*?\n\n!!s;
            $message{Content} = $text;
        }
        else {
            ##  Get the content/attachment boundary for this message. Apparently the first '()' is needed to embed the second '(' in the text, to delimit the boundary.
            $text =~ m!\n( boundary=")(-{12}[0-9A-F]{24})"!;
            my $boundary = "--$2";    ##  Two extra hyphens are added in messages.
            if ( ! defined $boundary ) {
                $_[ 6 ] = "Error: Cannot get boundary in message $message_id in $account\@$server";
                return 0;
            }

            ##  Get the message content. Skip the first $parts[ 0 ], which is the header of the message.
            my @parts = split /\n$boundary/, $text;
            $parts[ 1 ] =~ s!.*Content-Transfer-Encoding: 7bit\n+!!s;
            $message{Content} = $parts[ 1 ];

            ##  Process each attached file. Skip $parts[ 0 ] (header), $parts[ 1 ] (content), and last $parts[], which is the end of the message (two extra hyphens) after the last boundary.
            my @files;
            for ( my $part_num = 2; $part_num < $#Parts; ++$part_num ) {
                ##  Get the attached file encoding, name, and content.
                $parts[ $part_num ] =~ m!
                        (\nContent-Transfer-Encoding: )
                        (.*?)
                        (\n.*)
                        ( filename=")
                        (.*?)
                        ("\n+)
                        (.*)!sx;
                my %file;

                my $encoding = $2;

                my $file_name = $5;
                if ( defined $file_name ) {
                    $file{Name} = $file_name;
                }

                my $file_text = $7;
                if ( defined $file_text ) {
                    ##  If the content is encoded in Base64 MIME, then decode it.
                    if ( $encoding =~ m!base64! ) {
                        $file{Text} = mIME::Base64::decode( $file_text );
                    }
                    else {
                        $file_text =~ s!\n{3}$!!s;    ##  Remove any trailing newlines.
                        $file{Text} = $file_text;
                    }
                }

                $files[ $part_num - 2 ] = \%file;
            }

            ##  Add the file array reference to the message hash.
            $message{Files} = \@files;
        }

        ##  Mark the message for deletion.
        if ( "$delete_message" ne '' ) {
            if ( ! $pop->delete( $message_id ) ) {
                $_[ 6 ] = "Error: Cannot mark message $message_id for deletion in $account\@$server";
                return 0;
            }
        }

        ##  Add the message hash reference to the array.
        $_[ 5 ][ $message_num++ ] = \%message;
    }

    ##  Quit and close the connection to the remote POP3 server. Any messages marked for deletion will be deleted from the remote mailbox.
    $pop->quit() || die "Error: Cannot quit and close connection to server.\n";

    ##  Set the message indicating success, and return the status for success.
    $_[ 6 ] = "Info: Got $num_messages messages from $account\@$server";
    return 1;
}

sub mail_show_messages {
    ##  Show the email messages in the message structure.

    ##  This is the reference to the array of hash references, one for each message. The hash keys are Date, From, To, Subject, Content, Files. The Files value is a reference to the array, one for each attached file. The array element is a reference to the hash, keyed by Text and Name. The Text value is the file content. The Name value is the filename.
    my @messages = @{$_[ 0 ]};

    for ( my $message_num = 0; $message_num <= $#Messages; ++$message_num ) {
        my $message_ref = $messages[ $message_num ];
        my %message = %$message_ref;
        print '*' x 80, "\n";
        foreach my $key ( 'Date', 'From', 'To', 'Subject' ) {
            ##  Or use $$messages[ $message_num ]{ $key }
            print "$key: $message{ $key }\n";
        }
        print '=' x 80, "\n";
        print "$message{Content}\n";
        if ( defined $message{Files} ) {
            print '=' x 80, "\n";
            my $files_ref = $message{Files};
            my @files = @$files_ref;
            for ( my $file_num = 0; $file_num <= $#Files; ++$file_num ) {
                print "$files[ $file_num ]{Name}:\n";
                print "$files[ $file_num ]{Text}\n";
                print '-' x 80, "\n";
            }
        }
    }
}

sub string_from_array_ref {
    ##  Convert an array of strings into a single string. To keep the strings delimited, do not cho(m)p off any newlines.

    my @strings = @{$_[ 0 ]};    ##  Reference to an array of strings.
    my $string;
    for ( my $line_num = 0; $line_num <= $#Strings; ++$line_num ) {
        $string .= $strings[ $line_num ];
    }
    return $string;
}

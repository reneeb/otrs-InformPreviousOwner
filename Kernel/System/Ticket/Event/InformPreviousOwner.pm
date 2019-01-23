# --
# Copyright (C) 2019 Perl-Services.de, http://perl-services.de
# --
# This software comes with ABSOLUTELY NO WARRANTY. For details, see
# the enclosed file COPYING for license information (AGPL). If you
# did not receive this file, see http://www.gnu.org/licenses/agpl.txt.
# --

package Kernel::System::Ticket::Event::InformPreviousOwner;

use strict;
use warnings;

use List::Util qw(first);
use Mail::Address;

use Kernel::System::VariableCheck qw(:all);

our @ObjectDependencies = (
    'Kernel::Config',
    'Kernel::System::CustomerUser',
    'Kernel::System::CheckItem',
    'Kernel::System::DB',
    'Kernel::System::DynamicField',
    'Kernel::System::DynamicField::Backend',
    'Kernel::System::Email',
    'Kernel::System::Group',
    'Kernel::System::HTMLUtils',
    'Kernel::System::JSON',
    'Kernel::System::Log',
    'Kernel::System::NotificationEvent',
    'Kernel::System::Queue',
    'Kernel::System::SystemAddress',
    'Kernel::System::TemplateGenerator',
    'Kernel::System::Ticket',
    'Kernel::System::Ticket::Article',
    'Kernel::System::DateTime',
    'Kernel::System::User',
    'Kernel::System::CheckItem',
);

sub new {
    my ( $Type, %Param ) = @_;

    # allocate new hash for object
    my $Self = {};
    bless( $Self, $Type );

    return $Self;
}

sub Run {
    my ( $Self, %Param ) = @_;

    my $LogObject    = $Kernel::OM->Get('Kernel::System::Log');
    my $ConfigObject = $Kernel::OM->Get('Kernel::Config');
    my $TicketObject = $Kernel::OM->Get('Kernel::System::Ticket');

    # check needed stuff
    for my $Needed (qw(Event Data Config UserID)) {
        if ( !$Param{$Needed} ) {
            $LogObject->Log(
                Priority => 'error',
                Message  => "Need $Needed!",
            );
            return;
        }
    }

    if ( !$Param{Data}->{TicketID} ) {
        $LogObject->Log(
            Priority => 'error',
            Message  => 'Need TicketID in Data!',
        );
        return;
    }

    # return if no notification is active
    return 1 if $TicketObject->{SendNoNotification};

    # return if no ticket exists (e. g. it got deleted)
    my $TicketExists = $TicketObject->TicketNumberLookup(
        TicketID => $Param{Data}->{TicketID},
        UserID   => $Param{UserID},
    );

    return 1 if !$TicketExists;

    my %Ticket = $TicketObject->TicketGet(
        TicketID => $Param{Data}->{TicketID},
    );

    # get notification event object
    my $NotificationEventObject = $Kernel::OM->Get('Kernel::System::NotificationEvent');
    
    # get ID for Notification configured in Sysconfig
    my $Notification = $ConfigObject->Get('InformPreviousOwner::Notification');

    # return if no notification for event exists
    return 1 if !$Notification;

    my %List         = $NotificationEventObject->NotificationList();
    my %ReversedList = reverse %List;
    my $ID           = $ReversedList{$Notification};

    return 1 if !$ID;

    my %Notification = $NotificationEventObject->NotificationGet(
        ID => $ID,
    );

    my @NotificationBundle;

    # get template generator object
    my $TemplateGeneratorObject = $Kernel::OM->Get('Kernel::System::TemplateGenerator');

    # get previous owner
    my @RecipientUsers = $Self->_RecipientGet(
        Notification => \%Notification,
        Ticket       => \%Ticket,
        UserID       => $Param{UserID},
    );

    return 1 if !@RecipientUsers;
	
    # parse all notification tags for each user
    for my $Recipient (@RecipientUsers) {

        my %ReplacedNotification = $TemplateGeneratorObject->NotificationEvent(
            TicketData            => \%Ticket,
            Recipient             => $Recipient,
            Notification          => \%Notification,
            CustomerMessageParams => $Param{Data}->{CustomerMessageParams},
            UserID                => $Param{UserID},
        );

        my $UserNotificationTransport = $Kernel::OM->Get('Kernel::System::JSON')->Decode(
            Data => $Recipient->{NotificationTransport},
        );

        push @NotificationBundle, {
            Recipient                      => $Recipient,
            Notification                   => \%ReplacedNotification,
            RecipientNotificationTransport => $UserNotificationTransport,
        };
    }

    # get notification transport config
    my %TransportConfig = %{ $ConfigObject->Get('Notification::Transport') || {} };

    # remember already sent agent notifications
    my %AlreadySent;

    # loop over transports for each notification
    TRANSPORT:
    for my $Transport ( sort keys %TransportConfig ) {

        # only configured transports for this notification
        if ( !grep { $_ eq $Transport } @{ $Notification{Data}->{Transports} } ) {
            next TRANSPORT;
        }

        next TRANSPORT if !IsHashRefWithData( $TransportConfig{$Transport} );
        next TRANSPORT if !$TransportConfig{$Transport}->{Module};

        # get transport object
        my $TransportObject;
        eval {
            $TransportObject = $Kernel::OM->Get( $TransportConfig{$Transport}->{Module} );
        };

        if ( !$TransportObject ) {
            $Kernel::OM->Get('Kernel::System::Log')->Log(
                Priority => 'error',
                Message  => "Could not create a new $TransportConfig{$Transport}->{Module} object!",
            );

            next TRANSPORT;
        }

        if ( ref $TransportObject ne $TransportConfig{$Transport}->{Module} ) {
            $Kernel::OM->Get('Kernel::System::Log')->Log(
                Priority => 'error',
                Message  => "$TransportConfig{$Transport}->{Module} object is invalid",
            );

            next TRANSPORT;
        }

        # check if transport is usable
        next TRANSPORT if !$TransportObject->IsUsable();

        BUNDLE:
        for my $Bundle (@NotificationBundle) {

            my $UserPreference = "Notification-$Notification{ID}-$Transport";

            # check if agent should get the notification
            my $AgentSendNotification = 0;
            if ( defined $Bundle->{RecipientNotificationTransport}->{$UserPreference} ) {
                $AgentSendNotification = $Bundle->{RecipientNotificationTransport}->{$UserPreference};
            }
            elsif ( grep { $_ eq $Transport } @{ $Notification{Data}->{AgentEnabledByDefault} } ) {
                $AgentSendNotification = 1;
            }
            elsif (
                !IsArrayRefWithData( $Notification{Data}->{VisibleForAgent} )
                || (
                    defined $Notification{Data}->{VisibleForAgent}->[0]
                    && !$Notification{Data}->{VisibleForAgent}->[0]
                )
                )
            {
                $AgentSendNotification = 1;
            }

            # skip sending the notification if the agent has disable it in its preferences
            if (
                IsArrayRefWithData( $Notification{Data}->{VisibleForAgent} )
                && $Notification{Data}->{VisibleForAgent}->[0]
                && $Bundle->{Recipient}->{Type} eq 'Agent'
                && !$AgentSendNotification
                )
            {
                next BUNDLE;
            }

            # Check if notification should not send to the customer.
            if (
                $Bundle->{Recipient}->{Type} eq 'Customer'
                && $ConfigObject->Get('CustomerNotifyJustToRealCustomer')
                )
            {

                # No UserID means it's not a mapped customer.
                next BUNDLE if !$Bundle->{Recipient}->{UserID};
            }

            my $Success = $Self->_SendRecipientNotification(
                TicketID              => $Param{Data}->{TicketID},
                Notification          => $Bundle->{Notification},
                CustomerMessageParams => $Param{Data}->{CustomerMessageParams} || {},
                Recipient             => $Bundle->{Recipient},
                Event                 => $Param{Event},
                Attachments           => [],
                Transport             => $Transport,
                TransportObject       => $TransportObject,
                UserID                => $Param{UserID},
            );

            # remember to have sent
            if ( $Bundle->{Recipient}->{UserID} ) {
                $AlreadySent{ $Bundle->{Recipient}->{UserID} } = 1;
            }
        }

        # get special recipients specific for each transport
        my @TransportRecipients = $TransportObject->GetTransportRecipients(
            Notification => \%Notification,
            Ticket       => \%Ticket,
        );

        next TRANSPORT if !@TransportRecipients;

        RECIPIENT:
        for my $Recipient (@TransportRecipients) {

            # replace all notification tags for each special recipient
            my %ReplacedNotification = $TemplateGeneratorObject->NotificationEvent(
                TicketData            => \%Ticket,
                Recipient             => $Recipient,
                Notification          => \%Notification,
                CustomerMessageParams => $Param{Data}->{CustomerMessageParams} || {},
                UserID                => $Param{UserID},
            );

            my $Success = $Self->_SendRecipientNotification(
                TicketID              => $Param{Data}->{TicketID},
                Notification          => \%ReplacedNotification,
                CustomerMessageParams => $Param{Data}->{CustomerMessageParams} || {},
                Recipient             => $Recipient,
                Event                 => $Param{Event},
                Attachments           => [],
                Transport             => $Transport,
                TransportObject       => $TransportObject,
                UserID                => $Param{UserID},
            );
        }
    }

    return 1;
}

sub _PreviousOwner {
    my ($Self, %Param) = @_;

    # check needed params
    for my $Needed (qw(TicketID UserID)) {
        return if !$Param{$Needed};
    }

    # get needed objects
    my $TicketObject = $Kernel::OM->Get('Kernel::System::Ticket');

    my @History = $TicketObject->HistoryGet(
        TicketID => $Param{TicketID},
        UserID   => $Param{UserID},
    );

    return if !@History;

    @History = reverse @History;

    my $Current      = shift @History;
    my $CurrentOwner = $Current->{OwnerID};

    my $UserID;

    LINE:
    for my $Line ( @History ) {
        if ( $Line->{OwnerID} != $CurrentOwner ) {
            $UserID = $Line->{OwnerID};
            last LINE;
	}
    }

    return $UserID;
}

sub _RecipientGet {
    my ( $Self, %Param ) = @_;

    # check needed params
    for my $Needed (qw(Ticket Notification UserID)) {
        return if !$Param{$Needed};
    }

    # set local values
    my %Notification = %{ $Param{Notification} };
    my %Ticket       = %{ $Param{Ticket} };

    # get needed objects
    my $TicketObject = $Kernel::OM->Get('Kernel::System::Ticket');
    my $GroupObject  = $Kernel::OM->Get('Kernel::System::Group');
    my $ConfigObject = $Kernel::OM->Get('Kernel::Config');
    my $UserObject   = $Kernel::OM->Get('Kernel::System::User');
    my $LogObject    = $Kernel::OM->Get('Kernel::System::Log');

    my $UserID = $Self->_PreviousOwner( %Ticket, UserID => $Param{UserID} );

    return if !$UserID;
    return if $UserID == 1;

    # get time object
    my $DateTimeObject = $Kernel::OM->Create('Kernel::System::DateTime');

    my %User = $UserObject->GetUserData(
        UserID => $UserID,
        Valid  => 1,
    );
    next RECIPIENT if !%User;

    # skip users out of the office if configured
    if ( !$Notification{Data}->{SendOnOutOfOffice} && $User{OutOfOffice} ) {
        my $Start = sprintf(
            "%04d-%02d-%02d 00:00:00",
            $User{OutOfOfficeStartYear}, $User{OutOfOfficeStartMonth},
            $User{OutOfOfficeStartDay}
        );
        my $TimeStart = $Kernel::OM->Create(
            'Kernel::System::DateTime',
            ObjectParams => {
                String => $Start,
            },
        );
        my $End = sprintf(
            "%04d-%02d-%02d 23:59:59",
            $User{OutOfOfficeEndYear}, $User{OutOfOfficeEndMonth},
            $User{OutOfOfficeEndDay}
        );
        my $TimeEnd = $Kernel::OM->Create(
            'Kernel::System::DateTime',
            ObjectParams => {
                String => $End,
            },
        );

        next RECIPIENT if $TimeStart < $DateTimeObject && $TimeEnd > $DateTimeObject;
    }

    # skip PostMasterUserID
    my $PostmasterUserID = $ConfigObject->Get('PostmasterUserID') || 1;
    next RECIPIENT if $User{UserID} == $PostmasterUserID;

    $User{Type} = 'Agent';

    return \%User;
}

sub _SendRecipientNotification {
    my ( $Self, %Param ) = @_;

    # check needed stuff
    for my $Needed (qw(TicketID UserID Notification Recipient Event Transport TransportObject)) {
        if ( !$Param{$Needed} ) {
            $Kernel::OM->Get('Kernel::System::Log')->Log(
                Priority => 'error',
                Message  => "Need $Needed!",
            );
        }
    }

    # get ticket object
    my $TicketObject = $Kernel::OM->Get('Kernel::System::Ticket');

    # check if the notification needs to be sent just one time per day
    if ( $Param{Notification}->{Data}->{OncePerDay} && $Param{Recipient}->{UserLogin} ) {

        # get ticket history
        my @HistoryLines = $TicketObject->HistoryGet(
            TicketID => $Param{TicketID},
            UserID   => $Param{UserID},
        );

        # get last notification sent ticket history entry for this transport and this user
        my $LastNotificationHistory;
        if ( defined $Param{Recipient}->{Source} && $Param{Recipient}->{Source} eq 'CustomerUser' ) {
            $LastNotificationHistory = first {
                $_->{HistoryType} eq 'SendCustomerNotification'
                    && $_->{Name} eq
                    "\%\%$Param{Recipient}->{UserEmail}"
            }
            reverse @HistoryLines;
        }
        else {
            $LastNotificationHistory = first {
                $_->{HistoryType} eq 'SendAgentNotification'
                    && $_->{Name} eq
                    "\%\%$Param{Notification}->{Name}\%\%$Param{Recipient}->{UserLogin}\%\%$Param{Transport}"
            }
            reverse @HistoryLines;
        }

        if ( $LastNotificationHistory && $LastNotificationHistory->{CreateTime} ) {

            my $DateTimeObject = $Kernel::OM->Create('Kernel::System::DateTime');

            my $LastNotificationDateTimeObject = $Kernel::OM->Create(
                'Kernel::System::DateTime',
                ObjectParams => {
                    String => $LastNotificationHistory->{CreateTime},
                },
            );

            # do not send the notification if it has been sent already today
            if (
                $DateTimeObject->Format( Format => "%Y-%m-%d" ) eq
                $LastNotificationDateTimeObject->Format( Format => "%Y-%m-%d" )
                )
            {
                return;
            }
        }
    }

    my $TransportObject = $Param{TransportObject};

    # send notification to each recipient
    my $Success = $TransportObject->SendNotification(
        TicketID              => $Param{TicketID},
        UserID                => $Param{UserID},
        Notification          => $Param{Notification},
        CustomerMessageParams => $Param{CustomerMessageParams},
        Recipient             => $Param{Recipient},
        Event                 => $Param{Event},
        Attachments           => $Param{Attachments},
    );

    return if !$Success;

    if (
        $Param{Recipient}->{Type} eq 'Agent'
        && $Param{Recipient}->{UserLogin}
        )
    {

        # write history
        $TicketObject->HistoryAdd(
            TicketID     => $Param{TicketID},
            HistoryType  => 'SendAgentNotification',
            Name         => "\%\%$Param{Notification}->{Name}\%\%$Param{Recipient}->{UserLogin}\%\%$Param{Transport}",
            CreateUserID => $Param{UserID},
        );
    }

    my %EventData = %{ $TransportObject->GetTransportEventData() };

    return 1 if !%EventData;

    if ( !$EventData{Event} || !$EventData{Data} || !$EventData{UserID} ) {

        $Kernel::OM->Get('Kernel::System::Log')->Log(
            Priority => 'error',
            Message  => "Could not trigger notification post send event",
        );

        return;
    }

    # ticket event
    $TicketObject->EventHandler(
        %EventData,
    );

    return 1;
}

1;
